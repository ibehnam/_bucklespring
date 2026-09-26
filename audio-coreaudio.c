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
 * hot-plug and AirPlay, while the render callback keeps running. So there is nothing to
 * listen for and nothing to reopen. A stall watchdog (audio_play) stays as belt and braces:
 * if the render callback stops advancing, or the unit is provably not on the default
 * device any more, the unit is rebuilt. The mixer is ours: a few dozen one-shot voices,
 * constant-power pan, per-voice gain. That replaces both libopenal and the unmaintained
 * ALURE loader (previously fetched from archive.org) on this platform.
 */
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <unistd.h>

#include "buckle.h"

#define ENGINE_RATE      48000.0   /* client format on the unit's input scope; AUHAL converts to the device */
#define VOICES           32        /* simultaneous one-shot clicks; each is ~100 ms */
#define MAX_SAMPLES      512       /* main.c caches one handle per (scancode, press) */
#define STALL_NS         1500000000ULL   /* no render callback for this long while started ⇒ stalled */
#define RECOVER_GAP_NS   2000000000ULL   /* never rebuild the unit more often than this */
#define FOLLOW_CHECK_NS  2000000000ULL   /* how often audio_play re-verifies "unit is on the default" */

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

static AudioUnit g_unit;
static AudioDeviceID g_pinned;              /* -d: HALOutput bound to this id; 0 = DefaultOutput (follows) */
static _Atomic uint64_t g_renders;          /* render callbacks so far: the heartbeat the watchdog reads */
static uint64_t g_seen_renders, g_seen_ns;  /* last time the main thread saw the counter move */
static uint64_t g_recover_ns, g_follow_check_ns;
static int g_follow_misses;                 /* consecutive "not on the default device" observations */

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

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

/* ---- The output unit ------------------------------------------------------------------- */

static void on_unit_device(void *ref, AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement elem)
{
	(void)ref; (void)id; (void)scope; (void)elem;
	char buf[256];
	/* The unit comes from the callback, never the global: a rebuild may be disposing that. */
	device_name(unit_device(unit), buf, sizeof buf);
	if (buf[0]) fprintf(stderr, "buckle: output device is now \"%s\"\n", buf);
}

static void unit_destroy(void)
{
	if (!g_unit) return;
	AudioUnitRemovePropertyListenerWithUserData(g_unit, kAudioOutputUnitProperty_CurrentDevice, on_unit_device, NULL);
	AudioOutputUnitStop(g_unit);
	AudioUnitUninitialize(g_unit);
	AudioComponentInstanceDispose(g_unit);
	g_unit = NULL;
}

/* Build, initialise and start the unit. DefaultOutput unless a device was pinned with -d. */
static int unit_create(void)
{
	AudioComponentDescription desc = { kAudioUnitType_Output,
		g_pinned ? kAudioUnitSubType_HALOutput : kAudioUnitSubType_DefaultOutput,
		kAudioUnitManufacturer_Apple, 0, 0 };
	AudioComponent comp = AudioComponentFindNext(NULL, &desc);
	OSStatus st = comp ? AudioComponentInstanceNew(comp, &g_unit) : -1;
	if (st != noErr || !g_unit) { fprintf(stderr, "buckle: cannot create the output unit (%d)\n", (int)st); g_unit = NULL; return -1; }

	if (g_pinned)
		st = AudioUnitSetProperty(g_unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &g_pinned, sizeof g_pinned);
	AudioStreamBasicDescription fmt = { ENGINE_RATE, kAudioFormatLinearPCM,
		kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0 };
	if (st == noErr) st = AudioUnitSetProperty(g_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof fmt);
	AURenderCallbackStruct cb = { render, NULL };
	if (st == noErr) st = AudioUnitSetProperty(g_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
	if (st == noErr) AudioUnitAddPropertyListener(g_unit, kAudioOutputUnitProperty_CurrentDevice, on_unit_device, NULL);
	if (st == noErr) st = AudioUnitInitialize(g_unit);
	if (st == noErr) st = AudioOutputUnitStart(g_unit);
	if (st != noErr) {
		fprintf(stderr, "buckle: cannot start the output unit (%d)\n", (int)st);
		unit_destroy();
		return -1;
	}
	g_seen_renders = atomic_load(&g_renders);
	g_seen_ns = now_ns();
	g_follow_misses = 0;
	return 0;
}

int audio_open(const char *device)
{
	char buf[256];
	g_pinned = kAudioObjectUnknown;
	if (device) {
		g_pinned = device_by_name(device);
		if (g_pinned == kAudioObjectUnknown) { fprintf(stderr, "buckle: no output device named \"%s\"\n", device); return -1; }
	} else if (default_output() == kAudioObjectUnknown) {
		fprintf(stderr, "buckle: no default output device\n");
		return -1;
	}
	if (unit_create() != 0) return -1;
	device_name(unit_device(g_unit), buf, sizeof buf);
	if (g_pinned) fprintf(stderr, "buckle: output pinned to \"%s\"\n", buf);
	else          fprintf(stderr, "buckle: output follows the system default (now \"%s\")\n", buf);
	return 0;
}

void audio_close(void)
{
	unit_destroy();
}

/* ---- Samples ---------------------------------------------------------------------------- */

/* Decode any file CoreAudio can read to mono Float32 at ENGINE_RATE, once, for the process life. */
int audio_load(const char *path)
{
	if (nsamples >= MAX_SAMPLES) return 0;
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
	ExtAudioFileRef file = NULL;
	OSStatus st = url ? ExtAudioFileOpenURL(url, &file) : -1;
	if (url) CFRelease(url);
	if (st != noErr) { fprintf(stderr, "buckle: cannot open \"%s\" (%d)\n", path, (int)st); return 0; }

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
		fprintf(stderr, "buckle: cannot decode \"%s\" (%d)\n", path, (int)st);
		ExtAudioFileDispose(file);
		return 0;
	}
	uint32_t cap = (uint32_t)((double)src_frames * ENGINE_RATE / src.mSampleRate) + 4096, total = 0;
	float *pcm = calloc(cap, sizeof(float));
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
		fprintf(stderr, "buckle: cannot read \"%s\" (%d)\n", path, (int)st);
		free(pcm);
		return 0;
	}
	samples[++nsamples].pcm = pcm;
	samples[nsamples].frames = total;
	return nsamples;
}

/* ---- Watchdog: called on every play, before the click is queued ------------------------- */

static void recover(const char *why)
{
	uint64_t now = now_ns();
	if (now - g_recover_ns < RECOVER_GAP_NS) return;
	g_recover_ns = now;
	fprintf(stderr, "buckle: %s; rebuilding the output unit\n", why);
	unit_destroy();
	if (unit_create() == 0) {
		char buf[256];
		device_name(unit_device(g_unit), buf, sizeof buf);
		fprintf(stderr, "buckle: output unit rebuilt on \"%s\"\n", buf);
	}
}

static void watchdog(void)
{
	uint64_t now = now_ns(), renders = atomic_load_explicit(&g_renders, memory_order_relaxed);
	if (!g_unit) { recover("output unit missing"); return; }

	/* Heartbeat: a started unit renders every few milliseconds, so a counter that has not
	 * moved between two plays more than STALL_NS apart is a dead IO thread, whatever the
	 * unit claims. A device switch pauses rendering for ~100 ms; the threshold clears that. */
	if (renders != g_seen_renders) { g_seen_renders = renders; g_seen_ns = now; }
	else if (now - g_seen_ns > STALL_NS) { g_seen_ns = now; recover("output stalled (no render callback)"); return; }

	/* Follow check: the DefaultOutput unit moves itself, but prove it. Two consecutive
	 * observations of "not on the default device", spaced FOLLOW_CHECK_NS apart, mean the
	 * internal switch did not land; a fresh unit binds to the current default. */
	if (!g_pinned && now - g_follow_check_ns > FOLLOW_CHECK_NS) {
		g_follow_check_ns = now;
		AudioDeviceID want = default_output(), have = unit_device(g_unit);
		if (want != kAudioObjectUnknown && have != want) {
			if (++g_follow_misses >= 2) { g_follow_misses = 0; recover("output unit is not on the default device"); }
		} else {
			g_follow_misses = 0;
		}
	}
}

int audio_play(int sample, double pan, int gain_pct)
{
	if (sample <= 0 || sample > nsamples) return -1;
	watchdog();
	if (!g_unit || gain_pct <= 0) return 0;

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

/* --audio-check: open silently, prove the render thread runs and the unit sits on the device
 * it should (the system default, or the pinned one). Prints one line; 0 healthy, 1 not,
 * 2 no output device at all. The shell suite drives this. */
int audio_check(const char *device)
{
	char have[256], want[256];
	if (!device && default_output() == kAudioObjectUnknown) { printf("no output device\n"); return 2; }
	if (audio_open(device) != 0) return 1;
	uint64_t before = atomic_load(&g_renders);
	usleep(400000);
	uint64_t renders = atomic_load(&g_renders) - before;
	device_name(unit_device(g_unit), have, sizeof have);
	device_name(device ? g_pinned : default_output(), want, sizeof want);
	int ok = renders > 0 && strcmp(have, want) == 0;
	printf("device=\"%s\" expected=\"%s\" renders=%llu %s\n", have, want, (unsigned long long)renders, ok ? "ok" : "FAIL");
	audio_close();
	return ok ? 0 : 1;
}
