/*
 * Native CoreAudio output for macOS.
 *
 * Why not OpenAL here: openal-soft's CoreAudio backend pins a HALOutput unit to whatever
 * device id was the default at open time and never re-points it. Following the default was
 * left to the app through alcReopenDeviceSOFT, which (by its own comment) returns true even
 * when the new device fails to start, leaving a silent, disconnected device that nothing
 * detected or retried. That is the whole "headphones on, no clicks" family of bugs.
 *
 * The DefaultOutput AudioUnit is Apple's own answer to that question: it tracks the system
 * default output device inside CoreAudio, across AirPods pairing, Control Centre switches,
 * hot-plug and AirPlay. So there is nothing to listen for and nothing to reopen. The unit
 * runs only while clicks play: the first click starts it and it stops 30 s after the last,
 * because a started unit keeps a render thread busy and holds a sleep assertion around the
 * clock. While it runs, a timer on the main run loop proves it: a render counter that stops
 * advancing, or a unit provably not on the default device, gets the unit rebuilt. The mixer
 * is ours: a few dozen one-shot voices, constant-power pan, per-voice gain. That replaces
 * both libopenal and the unmaintained ALURE loader (previously fetched from archive.org) on
 * this platform.
 */
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>

#include "buckle.h"

#define ENGINE_RATE      48000.0   /* client format on the unit's input scope; AUHAL converts to the device */
#define VOICES           32        /* simultaneous one-shot clicks; each is ~100 ms */
#define MAX_SAMPLES      512       /* main.c caches one handle per (scancode, press) */
#define STALL_NS         1500000000ULL   /* a started unit with no render callback for this long has stalled */
#define RECOVER_GAP_NS   2000000000ULL   /* never rebuild the unit more often than this */
#define RECOVER_MAX_NS   300000000000ULL /* rebuilds that do not heal back off, doubling, up to this */
#define MONITOR_S        0.5             /* the timer's tick while the unit runs, seconds */
#define PARKED_S         1.0e9           /* the timer's next fire while the unit is stopped: never */
#define IDLE_NS          30000000000ULL  /* the unit stops this long after the last click */
#define LATE_NS          150000000ULL    /* a click whose start took longer is too late to play */
#define QUEUED_NS        50000000ULL     /* and so are the keys that queued behind that start */

struct sample { float *pcm; uint32_t frames; };
static struct sample samples[MAX_SAMPLES + 1];   /* handles are 1-based; 0 means failure */
static int nsamples;

enum { V_FREE = 0, V_ARMED = 1, V_PLAYING = 2 };
struct voice {
	_Atomic int state;
	const float *pcm;   /* the fields below are written by the main thread while ARMED and */
	uint32_t frames;    /* read/advanced by the render thread while PLAYING; the state store */
	uint32_t pos;       /* (release) / load (acquire) pair is the hand-over.               */
	float gl, gr;
};
static struct voice voices[VOICES];

static AudioUnit g_unit;                    /* initialised; started only while clicks play */
static int g_running;                       /* g_unit is started (main thread only) */
static AudioDeviceID g_pinned;              /* -d: HALOutput bound to this id; 0 = DefaultOutput (follows) */
static AudioDeviceID g_default;             /* the default output when last asked (wanted_device) */
static _Atomic uint64_t g_renders;          /* render callbacks so far: the counter the timer reads */
static uint64_t g_seen_renders, g_seen_ns;  /* last time the main thread saw the counter move */
static uint64_t g_recover_ns;               /* uptime of the last rebuild */
static uint64_t g_recover_gap = RECOVER_GAP_NS;   /* least uptime between two rebuilds (see recover) */
static int g_follow_misses;                 /* consecutive ticks that found the unit off the default device */
static uint64_t g_click_ns;                 /* uptime of the latest click that wanted to play */
static uint64_t g_late_until;               /* a click before this uptime queued behind a slow start */
static int g_slow_named;                    /* a slow start has named its device in this life's log */
static CFRunLoopTimerRef g_timer;           /* the tick; parked while the unit is stopped */

/* ---- CoreAudio device facts ------------------------------------------------------------ */

static OSStatus get_prop(AudioObjectID obj, AudioObjectPropertySelector sel, UInt32 *size, void *data)
{
	AudioObjectPropertyAddress addr = { sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	return AudioObjectGetPropertyData(obj, &addr, 0, NULL, size, data);
}

static void device_name(AudioDeviceID id, char *buf, size_t n)
{
	CFStringRef s = NULL;
	UInt32 size = sizeof s;
	buf[0] = '\0';
	if (id == kAudioObjectUnknown) return;
	if (get_prop(id, kAudioObjectPropertyName, &size, &s) == noErr && s) {
		CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
		CFRelease(s);
	}
}

static AudioDeviceID default_output(void)
{
	AudioDeviceID id = kAudioObjectUnknown;
	UInt32 size = sizeof id;
	get_prop(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, &size, &id);
	return id;
}

/* Devices that have at least one output stream, in HAL order. Returns the count. */
static int output_devices(AudioDeviceID *ids, int max)
{
	AudioObjectPropertyAddress addr = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	UInt32 size = 0;
	if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr) return 0;
	AudioDeviceID *all = malloc(size);
	if (!all || AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, all) != noErr) { free(all); return 0; }
	int n = (int)(size / sizeof(AudioDeviceID)), out = 0;
	for (int i = 0; i < n && out < max; i++) {
		AudioObjectPropertyAddress streams = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
		UInt32 ssize = 0;
		if (AudioObjectGetPropertyDataSize(all[i], &streams, 0, NULL, &ssize) == noErr && ssize > 0)
			ids[out++] = all[i];
	}
	free(all);
	return out;
}

/* Exact name first, then a unique substring (device names carry curly apostrophes). */
static AudioDeviceID device_by_name(const char *name)
{
	AudioDeviceID ids[64], hit = kAudioObjectUnknown;
	int n = output_devices(ids, 64), hits = 0;
	char buf[256];
	for (int i = 0; i < n; i++) {
		device_name(ids[i], buf, sizeof buf);
		if (strcmp(buf, name) == 0) return ids[i];
	}
	for (int i = 0; i < n; i++) {
		device_name(ids[i], buf, sizeof buf);
		if (strstr(buf, name)) { hit = ids[i]; hits++; }
	}
	return hits == 1 ? hit : kAudioObjectUnknown;
}

/* The device UNIT is rendering to right now (the DefaultOutput unit moves this itself). */
static AudioDeviceID unit_device(AudioUnit unit)
{
	AudioDeviceID id = kAudioObjectUnknown;
	UInt32 size = sizeof id;
	if (unit)
		AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size);
	return id;
}

void audio_list_devices(void)
{
	AudioDeviceID ids[64];
	int n = output_devices(ids, 64);
	char buf[256];
	printf("Available audio devices:");
	for (int i = 0; i < n; i++) {
		device_name(ids[i], buf, sizeof buf);
		printf(" \"%s\"", buf);
	}
	printf("\n");
}

/* ---- The mixer: render thread only ----------------------------------------------------- */

static OSStatus render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
		       UInt32 bus, UInt32 nframes, AudioBufferList *io)
{
	(void)ref; (void)flags; (void)ts; (void)bus;
	atomic_fetch_add_explicit(&g_renders, 1, memory_order_relaxed);
	for (UInt32 b = 0; b < io->mNumberBuffers; b++)
		memset(io->mBuffers[b].mData, 0, io->mBuffers[b].mDataByteSize);

	int interleaved = io->mNumberBuffers == 1 && io->mBuffers[0].mNumberChannels == 2;
	for (int v = 0; v < VOICES; v++) {
		struct voice *vc = &voices[v];
		if (atomic_load_explicit(&vc->state, memory_order_acquire) != V_PLAYING) continue;
		uint32_t n = vc->frames - vc->pos;
		if (n > nframes) n = nframes;
		const float *s = vc->pcm + vc->pos;
		if (interleaved) {
			float *out = io->mBuffers[0].mData;
			for (uint32_t i = 0; i < n; i++) { out[2 * i] += s[i] * vc->gl; out[2 * i + 1] += s[i] * vc->gr; }
		} else {
			for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
				float *out = io->mBuffers[b].mData, g = b == 0 ? vc->gl : vc->gr;
				UInt32 ch = io->mBuffers[b].mNumberChannels ? io->mBuffers[b].mNumberChannels : 1;
				for (uint32_t i = 0; i < n; i++) out[i * ch] += s[i] * g;
			}
		}
		vc->pos += n;
		if (vc->pos >= vc->frames)
			atomic_store_explicit(&vc->state, V_FREE, memory_order_release);
	}
	return noErr;
}

/* ---- The output unit: main thread ------------------------------------------------------ */

static void on_unit_device(void *ref, AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement elem)
{
	(void)ref; (void)id; (void)scope; (void)elem;
	char buf[256];
	/* The unit comes from the callback, never the global: a rebuild may be disposing that. */
	device_name(unit_device(unit), buf, sizeof buf);
	if (buf[0]) note("buckle: output device is now \"%s\"\n", buf);
}

/*
 * The output's state is two log lines, `output on` at each start and `output off` at each
 * stop, plus `output off until a key` at startup, since the unit starts parked; the status
 * cell paints the icon gray while the latest is off. Only a change writes one.
 */

/* No render thread is running: drop every voice, so a click left over from a stall never
 * plays at the next start, and park the timer. */
static void output_idle(void)
{
	if (g_running)
		note("buckle: output off\n");
	g_running = 0;
	for (int v = 0; v < VOICES; v++)
		atomic_store_explicit(&voices[v].state, V_FREE, memory_order_relaxed);
	if (g_timer)
		CFRunLoopTimerSetNextFireDate(g_timer, CFAbsoluteTimeGetCurrent() + PARKED_S);
}

static void unit_destroy(void)
{
	if (g_unit) {
		AudioUnitRemovePropertyListenerWithUserData(g_unit, kAudioOutputUnitProperty_CurrentDevice, on_unit_device, NULL);
		AudioOutputUnitStop(g_unit);
		AudioUnitUninitialize(g_unit);
		AudioComponentInstanceDispose(g_unit);
		g_unit = NULL;
	}
	output_idle();
}

/* Stop the unit: no render thread, no sleep assertion, no timer. AudioOutputUnitStop returns
 * only once the render callback is not running. A stop that fails disposes of the unit,
 * which ends its render thread just the same, and returns -1; the next click builds another. */
static int unit_stop(void)
{
	OSStatus st;

	if (g_running && (st = AudioOutputUnitStop(g_unit)) != noErr) {
		note("buckle: cannot stop the output unit (%d); disposing of it\n", (int)st);
		unit_destroy();
		return -1;
	}
	output_idle();
	return 0;
}

/* Build and initialise the unit, stopped. DefaultOutput unless a device was pinned with -d. */
static int unit_create(void)
{
	AudioComponentDescription desc = { kAudioUnitType_Output,
		g_pinned ? kAudioUnitSubType_HALOutput : kAudioUnitSubType_DefaultOutput,
		kAudioUnitManufacturer_Apple, 0, 0 };
	AudioComponent comp = AudioComponentFindNext(NULL, &desc);
	OSStatus st = comp ? AudioComponentInstanceNew(comp, &g_unit) : -1;
	if (st != noErr || !g_unit) { note("buckle: cannot create the output unit (%d)\n", (int)st); g_unit = NULL; return -1; }

	if (g_pinned)
		st = AudioUnitSetProperty(g_unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &g_pinned, sizeof g_pinned);
	AudioStreamBasicDescription fmt = { ENGINE_RATE, kAudioFormatLinearPCM,
		kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0 };
	if (st == noErr) st = AudioUnitSetProperty(g_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof fmt);
	AURenderCallbackStruct cb = { render, NULL };
	if (st == noErr) st = AudioUnitSetProperty(g_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
	if (st == noErr) AudioUnitAddPropertyListener(g_unit, kAudioOutputUnitProperty_CurrentDevice, on_unit_device, NULL);
	if (st == noErr) st = AudioUnitInitialize(g_unit);
	if (st != noErr) {
		note("buckle: cannot initialise the output unit (%d)\n", (int)st);
		unit_destroy();
		return -1;
	}
	return 0;
}

/*
 * Rebuild the unit, stopped, at most once per g_recover_gap of uptime (NOW is the caller's
 * reading). Every rebuild doubles the gap, up to RECOVER_MAX_NS, and the first tick that finds
 * the unit rendering on the device it should puts it back to RECOVER_GAP_NS, so a rebuild that
 * heals costs nothing later; a new default device ends the backoff at once (wanted_device). An
 * output that stays dead is rebuilt 4, 8, 16 ... 300 s apart instead, which bounds its log
 * lines the same way. A failed start, a stall, and a missed follow all share this one gap.
 */
static void recover(uint64_t now, const char *why)
{
	if (now - g_recover_ns < g_recover_gap) return;
	g_recover_ns = now;
	g_recover_gap = g_recover_gap < RECOVER_MAX_NS / 2 ? g_recover_gap * 2 : RECOVER_MAX_NS;
	note("buckle: %s; rebuilding the output unit\n", why);
	unit_destroy();
	if (unit_create() == 0) {
		char buf[256];
		device_name(unit_device(g_unit), buf, sizeof buf);
		note("buckle: output unit rebuilt on \"%s\"\n", buf);
	}
}

/* The device the unit should render to: the pinned one, or the system default now. A default
 * that changed since the last answer ends any rebuild backoff, so sound returns with the
 * device rather than minutes later. */
static AudioDeviceID wanted_device(void)
{
	AudioDeviceID want;

	if (g_pinned) return g_pinned;
	want = default_output();
	if (want != g_default) {
		g_default = want;
		g_recover_ns = 0;
		g_recover_gap = RECOVER_GAP_NS;
	}
	return want;
}

/* Start the built unit and arm the timer; a start that fails is a stall and disposes of the
 * unit, so the next click rebuilds it. 0 once it runs. */
static int unit_start(void)
{
	OSStatus st = AudioOutputUnitStart(g_unit);
	char why[64];

	if (st != noErr) {
		snprintf(why, sizeof why, "cannot start the output unit (%d)", (int)st);
		output_stalled(STALL_AUDIO, why);
		unit_destroy();
		return -1;
	}
	g_running = 1;
	note("buckle: output on\n");
	g_seen_renders = atomic_load(&g_renders);
	g_seen_ns = uptime_ns();
	g_follow_misses = 0;
	if (g_timer)
		CFRunLoopTimerSetNextFireDate(g_timer, CFAbsoluteTimeGetCurrent() + MONITOR_S);
	return 0;
}

/*
 * Start the unit for a click that arrived at NOW, rebuilding it first when it is missing or
 * sits off the default device: a stopped unit is never trusted to have followed a device
 * change. 0 when the click may play. A click whose unit became ready over LATE_NS after it
 * arrived plays too late, and the keys typed meanwhile queue behind it and arrive within
 * QUEUED_NS, so all of them are dropped: the rule engages only after a measured delay, so it
 * can never silence a fast device, and it reads no clock but this daemon's. A device whose
 * start alone took that long, rather than a rebuild before it, is named once per life.
 */
static int output_start(uint64_t now)
{
	AudioDeviceID want = wanted_device();
	uint64_t t, started;
	char buf[256];

	if (g_unit && !g_pinned && want != kAudioObjectUnknown && unit_device(g_unit) != want)
		recover(now, "the output unit is not on the default device");
	if (!g_unit)
		recover(now, "the output unit is missing");
	if (!g_unit) {
		output_stalled(STALL_AUDIO, want == kAudioObjectUnknown ? "no output device" : "no output unit");
		return -1;
	}
	t = uptime_ns();
	if (unit_start() != 0) return -1;
	started = uptime_ns() - t;
	if (uptime_ns() - now <= LATE_NS) return 0;
	if (started > LATE_NS && !g_slow_named) {
		g_slow_named = 1;
		device_name(unit_device(g_unit), buf, sizeof buf);
		note("buckle: output \"%s\" took %llu ms to start; a click that late, and the keys "
			"queued behind it, are dropped\n", buf, (unsigned long long)(started / 1000000));
	}
	g_late_until = uptime_ns() + QUEUED_NS;
	return -1;
}

/* Rebuild a unit that clicks are using, and start the new one at once: the tick can then prove
 * it renders and write the recovery, whether or not anyone types again, and the idle stop still
 * ends it 30 s after the last click. A rebuild the backoff holds back changes nothing. */
static void rebuild_running(uint64_t now, const char *why)
{
	recover(now, why);
	if (g_unit && !g_running)
		unit_start();
}

/*
 * Create and initialise the unit once, stopped: creating costs about 130 ms, paid here
 * rather than on a key, and the first click starts it. No output device at startup is not
 * fatal: the first click after one appears builds the unit. A pinned device that does not
 * exist is the caller's mistake, and is.
 */
int audio_open(const char *device)
{
	char buf[256];
	/* Supervision starts here, not at the tap watchdog's first tick: a jammed coreaudiod
	 * blocks this very call, and only a key thread that has pulsed can be seen to stop. */
	pulse();
	g_pinned = kAudioObjectUnknown;
	if (device) {
		g_pinned = device_by_name(device);
		if (g_pinned == kAudioObjectUnknown) { note("buckle: no output device named \"%s\"\n", device); return -1; }
	} else if (wanted_device() == kAudioObjectUnknown) {
		note("buckle: no default output device yet; the first click after one appears builds the output\n");
		return 0;
	}
	if (unit_create() != 0) return 0;
	device_name(unit_device(g_unit), buf, sizeof buf);
	if (g_pinned) note("buckle: output pinned to \"%s\"\n", buf);
	else          note("buckle: output follows the system default (now \"%s\")\n", buf);
	return 0;
}

void audio_close(void)
{
	unit_destroy();
}

/* ---- Samples ---------------------------------------------------------------------------- */

/* Decode any file CoreAudio can read to mono Float32 at ENGINE_RATE, once, for the process
 * life, trimmed to its length. */
int audio_load(const char *path)
{
	if (nsamples >= MAX_SAMPLES) return 0;
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
	ExtAudioFileRef file = NULL;
	OSStatus st = url ? ExtAudioFileOpenURL(url, &file) : -1;
	if (url) CFRelease(url);
	if (st != noErr) { note("buckle: cannot open \"%s\" (%d)\n", path, (int)st); return 0; }

	AudioStreamBasicDescription client = { ENGINE_RATE, kAudioFormatLinearPCM,
		kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 4, 1, 4, 1, 32, 0 };
	AudioStreamBasicDescription src = { 0 };
	SInt64 src_frames = 0;
	UInt32 size = sizeof src;
	st = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &src);
	size = sizeof src_frames;
	if (st == noErr) st = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &src_frames);
	if (st == noErr) st = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client);
	if (st != noErr || src.mSampleRate <= 0) {
		note("buckle: cannot decode \"%s\" (%d)\n", path, (int)st);
		ExtAudioFileDispose(file);
		return 0;
	}
	uint32_t cap = (uint32_t)((double)src_frames * ENGINE_RATE / src.mSampleRate) + 4096, total = 0;
	float *pcm = calloc(cap, sizeof(float)), *fit;
	if (!pcm) { ExtAudioFileDispose(file); return 0; }
	while (total < cap) {
		AudioBufferList bl;
		bl.mNumberBuffers = 1;
		bl.mBuffers[0].mNumberChannels = 1;
		bl.mBuffers[0].mDataByteSize = (cap - total) * (UInt32)sizeof(float);
		bl.mBuffers[0].mData = pcm + total;
		UInt32 n = cap - total;
		st = ExtAudioFileRead(file, &n, &bl);
		if (st != noErr || n == 0) break;
		total += n;
	}
	ExtAudioFileDispose(file);
	if (st != noErr || total == 0) {
		note("buckle: cannot read \"%s\" (%d)\n", path, (int)st);
		free(pcm);
		return 0;
	}
	if (total < cap && (fit = realloc(pcm, total * sizeof(float))))   /* the converter's headroom goes */
		pcm = fit;
	samples[++nsamples].pcm = pcm;
	samples[nsamples].frames = total;
	return nsamples;
}

/*
 * A new sound pack: drop every decoded sample, so main.c reloads them lazily from the new
 * directory. The render thread reads sample PCM through PLAYING voices, so the unit stops
 * first, which clears them; the next click starts it again. After a stop that failed, the old
 * PCM stays allocated rather than freed under a render thread the dispose may not have ended.
 */
void audio_forget_samples(void)
{
	int stopped = unit_stop() == 0;

	if (!stopped)
		note("buckle: keeping the old samples in memory after a failed stop\n");
	for (int i = 1; i <= nsamples && stopped; i++) {
		free(samples[i].pcm);
		samples[i].pcm = NULL;
		samples[i].frames = 0;
	}
	nsamples = 0;
}

/* ---- The timer: a main-run-loop tick, only while the unit runs -------------------------- */

static void monitor_tick(CFRunLoopTimerRef timer, void *info)
{
	(void)timer; (void)info;
	uint64_t now = uptime_ns(), renders = atomic_load_explicit(&g_renders, memory_order_relaxed);
	int advanced = renders != g_seen_renders, on_default = 1;

	pulse();   /* the key thread runs this timer: it is alive */
	if (!g_running) return;
	if (now - g_click_ns >= IDLE_NS) { unit_stop(); return; }

	/* A started unit renders every few milliseconds, so a counter that has not moved for
	 * STALL_NS is a dead IO thread, whatever the unit claims. NOW is uptime, which stops
	 * while the machine sleeps, so a wake is not a stall. A device switch pauses rendering
	 * for ~100 ms; the threshold clears that. */
	if (advanced) {
		g_seen_renders = renders;
		g_seen_ns = now;
		output_recovered(STALL_AUDIO);
	} else if (now - g_seen_ns > STALL_NS) {
		g_seen_ns = now;
		output_stalled(STALL_AUDIO, "no render callback for 1.5 s");
		rebuild_running(now, "the output stalled");
		return;
	}

	/* Follow check: the DefaultOutput unit moves itself, but prove it. Two consecutive ticks
	 * that find it off the default device mean the internal switch did not land; a fresh
	 * unit binds to the current default. */
	if (!g_pinned) {
		AudioDeviceID want = wanted_device(), have = unit_device(g_unit);
		on_default = want == kAudioObjectUnknown || have == want;
		if (on_default) {
			g_follow_misses = 0;
		} else if (++g_follow_misses >= 2) {
			g_follow_misses = 0;
			rebuild_running(now, "the output unit is not on the default device");
			return;
		}
	}

	/* The first tick that sees the counter advance, on the device the unit should be on,
	 * ends any backoff. The device counts as well as the counter: a unit rendering to the
	 * wrong device would otherwise reset the backoff on every tick. */
	if (advanced && on_default)
		g_recover_gap = RECOVER_GAP_NS;
}

/*
 * Create the timer on the MAIN run loop in the common modes, which is the loop scan() runs
 * with CFRunLoopRun on the main thread, parked until the first start. Called once, after
 * audio_open. The argument is retired with the render.hb heartbeat; the interface keeps it
 * for the backends this host cannot build.
 */
void audio_monitor(const char *heartbeat_path)
{
	(void)heartbeat_path;
	note("buckle: output off until a key\n");
	g_timer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + PARKED_S, MONITOR_S,
				       0, 0, monitor_tick, NULL);
	if (!g_timer) {
		note("buckle: cannot create the output timer; a started output never stops\n");
		return;
	}
	CFRunLoopTimerSetTolerance(g_timer, MONITOR_S / 5);   /* let the system coalesce wakeups */
	CFRunLoopAddTimer(CFRunLoopGetMain(), g_timer, kCFRunLoopCommonModes);
}

int audio_play(int sample, double pan, int gain_pct)
{
	uint64_t now;

	if (sample <= 0 || sample > nsamples) return -1;
	if (gain_pct <= 0) return 0;
	now = uptime_ns();
	g_click_ns = now;
	if (now < g_late_until) return 0;   /* typed during a slow start: too late to play */
	if (!g_running && output_start(now) != 0) return -1;

	/* Constant-power pan: pan -1 = left, +1 = right, 0 = centre at -3 dB per side. */
	if (pan < -1) pan = -1;
	if (pan > 1) pan = 1;
	double theta = (pan + 1.0) * M_PI / 4.0;
	float g = gain_pct / 100.0f;

	struct voice *vc = NULL;
	for (int i = 0; i < VOICES; i++) {
		int expect = V_FREE;
		if (atomic_compare_exchange_strong(&voices[i].state, &expect, V_ARMED)) { vc = &voices[i]; break; }
	}
	if (!vc) return -1;   /* VOICES overlapping clicks: drop this one rather than stall the tap */
	vc->pcm = samples[sample].pcm;
	vc->frames = samples[sample].frames;
	vc->pos = 0;
	vc->gl = g * (float)cos(theta);
	vc->gr = g * (float)sin(theta);
	atomic_store_explicit(&vc->state, V_PLAYING, memory_order_release);
	return 0;
}

/* --audio-check: open silently, start the unit as a click would, prove the render thread runs
 * on the device it should (the system default, or the pinned one), then stop it as the idle
 * timer would and prove the rendering stopped. Prints one line; 0 healthy, 1 not, 2 no output
 * device at all. The shell suite drives this. */
int audio_check(const char *device)
{
	char have[256], want[256];
	uint64_t t, started, stopped, renders, after;

	if (!device && default_output() == kAudioObjectUnknown) { printf("no output device\n"); return 2; }
	if (audio_open(device) != 0) return 1;
	t = uptime_ns();
	output_start(t);   /* a slow start still starts: the verdict below judges the unit */
	started = uptime_ns() - t;
	if (!g_running) { printf("the output unit did not start FAIL\n"); audio_close(); return 1; }
	renders = atomic_load(&g_renders);
	usleep(400000);
	renders = atomic_load(&g_renders) - renders;
	device_name(unit_device(g_unit), have, sizeof have);
	device_name(device ? g_pinned : default_output(), want, sizeof want);
	t = uptime_ns();
	int clean = unit_stop() == 0;   /* a stop that had to dispose of the unit fails the check */
	stopped = uptime_ns() - t;
	after = atomic_load(&g_renders);
	usleep(100000);
	after = atomic_load(&g_renders) - after;
	int ok = renders > 0 && after == 0 && clean && strcmp(have, want) == 0;
	printf("device=\"%s\" expected=\"%s\" renders=%llu start=%llums stop=%llums renders-after-stop=%llu %s\n",
	       have, want, (unsigned long long)renders, (unsigned long long)(started / 1000000),
	       (unsigned long long)(stopped / 1000000), (unsigned long long)after, ok ? "ok" : "FAIL");
	audio_close();
	return ok ? 0 : 1;
}
