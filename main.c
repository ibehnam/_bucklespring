#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <stdint.h>
#include <inttypes.h>
#include <unistd.h>
#include <limits.h>
#include <stdbool.h>
#include <getopt.h>
#include <time.h>
#include <stdatomic.h>

#include <AL/al.h>
#include <AL/alc.h>
#include <AL/alext.h>
#include <AL/alure.h>

#include "buckle.h"

#define SRC_INVALID INT_MAX
#define DEFAULT_MUTE_KEYCODE 0x46 /* Scroll Lock */

#define TEST_ERROR(_msg)		\
	error = alGetError();		\
	if (error != AL_NO_ERROR) {	\
		fprintf(stderr, _msg "\n");	\
		exit(1);		\
	}


static void usage(char *exe);
static void list_devices(void);
static double find_key_loc(int code);



/* 
 * Horizontal position on keyboard for each key as they are located on my model-M
 */

static int keyloc[][32] = {
	{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x6e, 0x66, 0x68, 0x1c, 0x45, 0x62, 0x37, 0x4a, -1 },
	{ 0x01, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58, 0x6f, 0x6b, 0x6d, 0x47, 0x48, 0x49, 0x4e, -1 },
	{ 0x29, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x4b, 0x4c, 0x4d, -1 },
	{ 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x2b, 0x4f, 0x50, 0x51, 0x60, -1 },
	{ 0x3a, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x1c, 0x52, 0x53, -1 },
	{ 0x2a, 0x56, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, -1 },
	{ 0x1d, 0x7d, 0x5b, 0x38, 0x39, 0x64, 0x7e, 0x61, 0x67, -1 },
	{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x69, 0x6c, 0x6a, -1 },
};

/* 
 * Horizontal position on keyboard of the pragmatic center of the row, since keys come in different sizes and shapes
 */
static double midloc[] = {
	7.5,
	7.5,
	7.5,
	6.5,
	6.5,
	6.5,
	4.5,
};

static int opt_verbose = 0;
static int opt_no_click = 0;
static int opt_stereo_width = 50;
static int opt_gain = 100;
static int opt_fallback_sound = 0;
static int opt_mute_keycode = DEFAULT_MUTE_KEYCODE;
static const char *opt_device = NULL;
static const char *opt_path_audio = PATH_AUDIO;
static int muted = 0;

/*
 * Quiet hours: a gain window evaluated at PLAY time rather than at configure time,
 * so a running buckle dims and un-dims on the clock with no timer, no daemon, and no
 * relaunch at the boundary. Bounds are MINUTES since midnight — the same unit and the
 * same three-branch rule as the shell's tmux_quiet_active (AI/tmux-ui-lib.sh in the
 * tmux config that launches this), which --gain-at exists to prove agreement with.
 * from == to is the OFF encoding and the DEFAULT, so a buckle launched without these
 * flags behaves byte-identically to before they existed.
 */
static int opt_quiet_from = 0;
static int opt_quiet_to = 0;
static int opt_quiet_gain = 0;

/* Long-only options: values above the char range so they can't collide with short_opts. */
enum {
	OPT_QUIET_FROM = 256,
	OPT_QUIET_TO,
	OPT_QUIET_GAIN,
	OPT_GAIN_AT,
};

static const char short_opts[] = "d:fg:hlm:Mp:s:cv";

static const struct option long_opts[] = {
	{ "device",         required_argument, NULL, 'd' },
	{ "fallback-sound", no_argument,       NULL, 'f' },
	{ "gain",           required_argument, NULL, 'g' },
	{ "help",           no_argument,       NULL, 'h' },
	{ "list-devices",   no_argument,       NULL, 'l' },
	{ "mute-keycode",   required_argument, NULL, 'm' },
	{ "mute",           no_argument,       NULL, 'M' },
	{ "audio-path",     required_argument, NULL, 'p' },
	{ "stereo-width",   required_argument, NULL, 's' },
	{ "no-click",       no_argument,       NULL, 'c' },
	{ "verbose",        no_argument,       NULL, 'v' },
	{ "quiet-from",     required_argument, NULL, OPT_QUIET_FROM },
	{ "quiet-to",       required_argument, NULL, OPT_QUIET_TO },
	{ "quiet-gain",     required_argument, NULL, OPT_QUIET_GAIN },
	{ "gain-at",        required_argument, NULL, OPT_GAIN_AT },
        { 0, 0, 0, 0 }
};

/*
 * Is NOW (minutes since midnight) inside the quiet window? from == to ⇒ off;
 * from < to ⇒ a same-day window; from > to ⇒ one that wraps midnight. Start
 * inclusive, end exclusive. This is the design's ONLY rule duplicated between C and
 * the shell, which is why --gain-at exposes it to the shell test suite.
 */
static int in_quiet(int now)
{
	if (opt_quiet_from == opt_quiet_to) return 0;
	if (opt_quiet_from < opt_quiet_to)  return now >= opt_quiet_from && now < opt_quiet_to;
	return now >= opt_quiet_from || now < opt_quiet_to;
}

/* The gain a click at minute-of-day NOW must play at. --gain-at's seam. */
static int gain_at(int now)
{
	return in_quiet(now) ? opt_quiet_gain : opt_gain;
}

/*
 * The gain THIS click must play at. play() runs inside the macOS CGEventTap callback,
 * where a slow callback is exactly what gets the tap disabled by the system, so the
 * clock work is guarded twice:
 *   • quiet disabled (the default, and the state buckle ships in) ⇒ return immediately;
 *     one integer compare, no clock read at all;
 *   • enabled ⇒ time() only — a commpage read, not a syscall — with localtime_r run at
 *     most once per wall-clock minute, so typing speed is irrelevant.
 * localtime_r, not localtime: an ALC event-callback thread runs alongside this one, and
 * localtime() hands back a shared static struct tm.
 */
static int effective_gain(void)
{
	static time_t cached_minute = -1;
	static int cached_now = 0;
	time_t now;
	struct tm tm;

	if (opt_quiet_from == opt_quiet_to) return opt_gain;

	now = time(NULL);
	if (now / 60 != cached_minute) {
		localtime_r(&now, &tm);
		cached_minute = now / 60;
		cached_now = tm.tm_hour * 60 + tm.tm_min;
	}
	return gain_at(cached_now);
}



/*
 * Audio device + context. openal-soft's CoreAudio backend never migrates to a
 * new default output on its own — it only notifies — so the app must re-point.
 * Its cached device enumeration (alcGetString) is NOT refreshed mid-process, but
 * alcReopenDeviceSOFT(dev, NULL, ...) re-resolves the *live* default via the
 * backend (verified), so on the library's own DefaultDeviceChanged event we flag,
 * and the next play() reopens the existing device+context onto the new default.
 * The process stays put — Stop still works, and sources/buffers survive the reopen.
 */
static ALCdevice  *device  = NULL;
static ALCcontext *context = NULL;
static LPALCREOPENDEVICESOFT g_reopen = NULL;   /* live default re-resolver */
static atomic_int g_reacquire = 0;              /* set by the ALC event callback */

/* Lazily-loaded per-key buffers/sources, keyed by code + press*256. */
static ALuint snd_buf[512] = { 0 };
static ALuint snd_src[512] = { 0 };
/* What gain each live source currently carries, so the per-play path issues alSourcef
 * only on an actual CHANGE (steady state: one integer compare, zero OpenAL calls). Seeded
 * to -1 where the source is created — plain static zero-init would be wrong, 0 is a valid
 * gain — which forces the first apply without a separate init loop. */
static int applied_gain[512];

/* Open the output device + context and make it current. On a fresh process the
 * default specifier resolves to the current system default output. */
static int open_audio(void)
{
	static const ALfloat listenerOri[] = { 0.0f, 0.0f, 1.0f, 0.0f, 1.0f, 0.0f };
	const ALCchar *name = opt_device;

	if (!name) {
		name = alcGetString(NULL, ALC_DEFAULT_ALL_DEVICES_SPECIFIER);
	}
	fprintf(stderr, "buckle: opening OpenAL output device \"%s\"\n", name ? name : "(default)");

	device = alcOpenDevice(name);
	if (!device) {
		fprintf(stderr, "buckle: unable to open audio device\n");
		return -1;
	}

	context = alcCreateContext(device, NULL);
	if (!context || !alcMakeContextCurrent(context)) {
		fprintf(stderr, "buckle: failed to make audio context current\n");
		if (context) { alcDestroyContext(context); context = NULL; }
		alcCloseDevice(device);
		device = NULL;
		return -1;
	}

	(void)alGetError();
	alListener3f(AL_POSITION, 0, 0, 0);
	alListener3f(AL_VELOCITY, 0, 0, 0);
	alListenerfv(AL_ORIENTATION, listenerOri);
	return 0;
}

static void close_audio(void)
{
	alcMakeContextCurrent(NULL);
	if (context) { alcDestroyContext(context); context = NULL; }
	if (device)  { alcCloseDevice(device);     device  = NULL; }
}

/* Re-point the open device+context onto the current system default. Safe to call
 * from the main thread (play()); alcReopenDeviceSOFT preserves sources/buffers. */
static void reacquire_default(void)
{
	if (!g_reopen || !device) return;
	if (g_reopen(device, NULL, NULL) == ALC_TRUE) {
		const ALCchar *now = alcGetString(device, ALC_ALL_DEVICES_SPECIFIER);
		fprintf(stderr, "buckle: followed default to \"%s\"\n", now ? now : "(default)");
	} else {
		fprintf(stderr, "buckle: alcReopenDeviceSOFT failed; will retry\n");
		atomic_store(&g_reacquire, 1);   /* retry on the next keystroke */
	}
}

/*
 * openal-soft system-events callback. Runs asynchronously on a background
 * thread, where the spec forbids AL/ALC calls — so it only sets a flag; the
 * next play() performs the reopen on the main thread.
 */
static void ALC_APIENTRY on_alc_event(ALCenum eventType, ALCenum deviceType,
				      ALCdevice *dev, ALCsizei length,
				      const ALCchar *message, void *user)
{
	(void)dev; (void)length; (void)message; (void)user;
	if (eventType == ALC_EVENT_TYPE_DEFAULT_DEVICE_CHANGED_SOFT &&
	    deviceType == ALC_PLAYBACK_DEVICE_SOFT) {
		fprintf(stderr, "buckle: default output device changed\n");
		atomic_store(&g_reacquire, 1);
	}
}

/* Subscribe to default-output-device changes via ALC_SOFT_system_events. This
 * reuses the listener openal-soft already runs internally — no second listener. */
static void subscribe_default_device_events(void)
{
	if (!alcIsExtensionPresent(NULL, "ALC_SOFT_system_events")) {
		fprintf(stderr, "buckle: ALC_SOFT_system_events unavailable; not following default device\n");
		return;
	}

	g_reopen = (LPALCREOPENDEVICESOFT) alcGetProcAddress(NULL, "alcReopenDeviceSOFT");
	LPALCEVENTCONTROLSOFT  event_control  = (LPALCEVENTCONTROLSOFT)  alcGetProcAddress(NULL, "alcEventControlSOFT");
	LPALCEVENTCALLBACKSOFT event_callback = (LPALCEVENTCALLBACKSOFT) alcGetProcAddress(NULL, "alcEventCallbackSOFT");
	if (!g_reopen || !event_control || !event_callback) {
		fprintf(stderr, "buckle: reopen/system-events functions unavailable; not following default device\n");
		return;
	}

	const ALCenum events[] = { ALC_EVENT_TYPE_DEFAULT_DEVICE_CHANGED_SOFT };
	event_callback(on_alc_event, NULL);
	event_control(1, events, ALC_TRUE);
	fprintf(stderr, "buckle: following system default output device\n");
}


int main(int argc, char **argv)
{
	int c;
	int rv = EXIT_SUCCESS;
	int idx;

	while( (c = getopt_long(argc, argv,
			       short_opts, long_opts, &idx)) != -1) {
		switch(c) {
			case 'd':
				opt_device = optarg;
				break;
			case 'f':
				opt_fallback_sound = 1;
				break;
			case 'g':
				opt_gain = atoi(optarg);
				break;
			case 'h':
				usage(argv[0]);
				return 0;
			case 'l':
				list_devices();
				return 0;
			case 'm':
				opt_mute_keycode = strtol(optarg, NULL, 0);
				break;
			case 'M':
				muted = !muted;
				break;
			case 'p': {
				size_t len = strlen(optarg);
				if (len > 1 && optarg[len - 1] == '/')
					optarg[len - 1] = '\0';
				opt_path_audio = optarg;
				break;
			}
			case 's':
				opt_stereo_width = atoi(optarg);
				break;
			case 'c':
				opt_no_click++;
				break;
			case 'v':
				opt_verbose++;
				break;
			case OPT_QUIET_FROM:
				opt_quiet_from = atoi(optarg);
				break;
			case OPT_QUIET_TO:
				opt_quiet_to = atoi(optarg);
				break;
			case OPT_QUIET_GAIN:
				opt_quiet_gain = atoi(optarg);
				break;
			case OPT_GAIN_AT:
				/* Print the rule's answer for one minute-of-day and exit — the seam
				 * the shell suite drives to prove in_quiet() and tmux_quiet_active
				 * agree. Reads the gain options parsed BEFORE it on the argv. */
				printf("%d\n", gain_at(atoi(optarg)));
				return 0;
			default:
				usage(argv[0]);
				return 1;
				break;
		}
	}

	if(opt_verbose) {
		open_console();
	}

	/* Path to data files can also be specified by environment, this is
	 * used by the snap package */

	const char *env_path = getenv("BUCKLESPRING_WAV_DIR");
	if (env_path) {
		opt_path_audio = env_path;
	}

	/* Open the output device. When no device was pinned with -d, also follow the
	 * system default: subscribe to openal-soft's DefaultDeviceChanged event and
	 * re-exec on change so a fresh process opens the new default. */

	if (open_audio() != 0) {
		rv = EXIT_FAILURE;
		goto out;
	}

	if (opt_device == NULL) {
		subscribe_default_device_events();
	}

	printd("Using wav dir: \"%s\"\n", opt_path_audio);

	scan(opt_verbose);

out:
	close_audio();

	return rv;
}


static void usage(char *exe)
{
	fprintf(stderr, 
		"bucklespring version " VERSION "\n"
		"usage: %s [options]\n"
		"\n"
		"options:\n"
		"\n"
		"  -d, --device=DEVICE       use OpenAL audio device DEVICE\n"
		"  -f, --fallback-sound      use a fallback sound for unknown keys\n"
		"  -g, --gain=GAIN           set playback gain [0..100]\n"
		"  -m, --mute-keycode=CODE   use CODE as mute key (default 0x46 for scroll lock)\n"
		"  -M, --mute                start the program muted\n"
		"  -c, --no-click            don't play a sound on mouse click\n"
		"  -h, --help                show help\n"
		"  -l, --list-devices        list available OpenAL audio devices\n"
		"  -p, --audio-path=PATH     load .wav files from directory PATH\n"
		"  -s, --stereo-width=WIDTH  set stereo width [0..100]\n"
		"  -v, --verbose             increase verbosity / debugging\n"
		"      --quiet-from=MIN      start of the quiet-hours window, minutes since midnight\n"
		"      --quiet-to=MIN        end of the quiet-hours window (exclusive); equal to\n"
		"                            --quiet-from (the default) disables the window\n"
		"      --quiet-gain=GAIN     gain [0..100] used inside the window (default 0)\n"
		"      --gain-at=MIN         print the gain a click at MIN would play at, and exit\n",
		exe
       );
}

static void list_devices(void)
{
	const ALCchar *devices = alcGetString(NULL, ALC_ALL_DEVICES_SPECIFIER);
	const ALCchar *device = devices, *next = devices + 1;
	size_t len = 0;

	printf("Available audio devices:");
	while (device && *device != '\0' && next && *next != '\0') {
		fprintf(stdout, " \"%s\"", device);
		len = strlen(device);
		device += (len + 1);
		next += (len + 2);
	}
	printf("\n");
}


void printd(const char *fmt, ...)
{
	if(opt_verbose) {
		
		char buf[256];
		va_list va;

		va_start(va, fmt);
		vsnprintf(buf, sizeof(buf), fmt, va);
		va_end(va);

		fprintf(stderr, "%s\n", buf);
	}
}


/*
 * Find horizontal position of the given key on the keyboard. returns -1.0 for
 * left to 1.0 for right 
 */

static double find_key_loc(int code)
{
	int row;
	int col, keycol = 0;

	for(row=0; row<8; row++) {
		for(col=0; col<32; col++) {
			if(keyloc[row][col] == code) keycol = col+1;
			if(keyloc[row][col] == -1) break;
		}
		if(keycol) {
			return ((double) keycol-midloc[row])/(col-midloc[row]);
		}
	}
	return 0;
}


/*
 * To silence play temporarily, press mute key (default ScrollLock) within 2
 * seconds, same to unmute
 */


static void handle_mute_key(int mute_key)
{
	static time_t t_prev;
	static int count = 0;

	if(mute_key) {
		time_t t_now = time(NULL);
		if(t_now - t_prev < 2) {
			count ++;
			if(count == 2) {
				muted = !muted;
				printd("Mute %s", muted ? "enabled" : "disabled");
				count = 0;
			}
		} else {
			count = 1;
		}
		t_prev = t_now;
	} else {
		count = 0;
	}
}


/*
 * Right-side modifier keys (RCtrl, RAlt, RMeta) share a keyswitch type with
 * their left counterparts — same recorded sound, different stereo position.
 * Route wav lookup to the L-counterpart's file so third-party sound packs
 * that only provide L-variants (e.g. klack-converted packs, or bucklespring's
 * own baseline where 7e-*.wav was never recorded) work out of the box.
 * Position lookup via find_key_loc(code) still uses the full code, so L/R
 * pan to their own speakers. Shift stays distinct (LShift=0x2a, RShift=0x36
 * have distinct recordings on the Model-M).
 */
static int wav_code_of(int code)
{
	switch (code) {
		case 0x61: return 0x1d;  /* RCtrl → LCtrl wav */
		case 0x64: return 0x38;  /* RAlt  → LAlt  wav */
		case 0x7e: return 0x5b;  /* RMeta → LMeta wav */
		case 0xfe: return 0x1c;  /* synthetic scancode for macOS NX_SYSDEFINED (consumer/media keys, Karabiner consumer_key_code) → Enter click */
		default:   return code;
	}
}


/*
 * Play audio file for given keycode. Wav files are loaded on demand
 */

int play(int code, int press)
{
	ALCenum error;

	printd("scancode %d/0x%x", code, code);

	/* Scanner couldn't map this physical key (e.g. Fn/Globe on mac) — drop silently. */
	if (code == 0) return 0;

	if (code == 0xff && opt_no_click) return 0;

	/* Follow a default-output-device change (flagged by the ALC event callback)
	 * before this click sounds: alcReopenDeviceSOFT re-points to the live default. */
	if (atomic_exchange(&g_reacquire, 0)) {
		reacquire_default();
	}

	/* Check for mute sequence: ScrollLock down+up+down */

	if (press) {
		handle_mute_key(code == opt_mute_keycode);
	}

	int idx = code + press * 256;

	if(snd_src[idx] == 0) {

		char fname[256];
		snprintf(fname, sizeof(fname), "%s/%02x-%d.wav", opt_path_audio, wav_code_of(code), press);

		printd("Loading audio file \"%s\"", fname);

		snd_buf[idx] = alureCreateBufferFromFile(fname);
		if(snd_buf[idx] == 0) {

			if(opt_fallback_sound) {
				snprintf(fname, sizeof(fname), "%s/%02x-%d.wav", opt_path_audio, 0x31, press);
				snd_buf[idx] = alureCreateBufferFromFile(fname);
			} else {
				fprintf(stderr, "Error opening audio file \"%s\": %s\n", fname, alureGetErrorString());
			}

			if(snd_buf[idx] == 0) {
				snd_src[idx] = SRC_INVALID;
				return -1;
			}
		}
	
		alGenSources((ALuint)1, &snd_src[idx]);
		error = alGetError();
		if (error != AL_NO_ERROR) {
			fprintf(stderr, "buckle: source generation error 0x%x; dropping click\n", error);
			snd_src[idx] = 0;
			return -1;
		}

		double x = find_key_loc(code);
		if (opt_stereo_width > 0) {
			alSource3f(snd_src[idx], AL_POSITION, -x, 0, (100 - opt_stereo_width) / 100.0);
		}
		applied_gain[idx] = -1;   /* no gain applied yet; the per-play block below sets it */

		alSourcei(snd_src[idx], AL_BUFFER, snd_buf[idx]);
		(void)alGetError();   /* non-fatal: a transient bind error won't kill the daemon */
	}


	if(snd_src[idx] != 0 && snd_src[idx] != SRC_INVALID) {
		/* Gain belongs on the PER-PLAY path, not the source-creation branch: sources are
		 * cached per (keycode, press) for the process lifetime, so setting it at creation
		 * froze each key's gain at its first press — no quiet window could ever take
		 * effect on a key already typed. Guarded by the applied_gain compare, so in steady
		 * state this costs one integer compare and zero OpenAL calls; only the first press
		 * of each key after a window boundary pays a single alSourcef. */
		int gain = effective_gain();
		if (gain != applied_gain[idx]) {
			alSourcef(snd_src[idx], AL_GAIN, gain / 100.0);
			applied_gain[idx] = gain;
			printd("gain %d%% applied to source %d", gain, idx);
		}
		if (!muted)
			alSourcePlay(snd_src[idx]);
		error = alGetError();
		if (error != AL_NO_ERROR) {
			/* Non-fatal: don't let a transient AL error kill the daemon. */
			fprintf(stderr, "buckle: playback error 0x%x; dropping click\n", error);
		}
	}

	return 0;
}



/*
 * End
 */
