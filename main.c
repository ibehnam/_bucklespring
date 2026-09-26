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
#include <math.h>
#include <signal.h>

#include "buckle.h"

#define DEFAULT_MUTE_KEYCODE 0x46 /* Scroll Lock */


static void usage(char *exe);
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
	OPT_AUDIO_CHECK,
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
	{ "audio-check",    no_argument,       NULL, OPT_AUDIO_CHECK },
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
 * localtime_r, not localtime: CoreAudio notification threads run alongside this one, and
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
 * Loaded samples, one backend handle per code + press*256: 0 = not loaded yet,
 * -1 = the file is missing (tried once, never again). The backend owns the
 * output device, the mixer and every per-play gain and pan (buckle.h).
 */
static int snd[512];


/*
 * Termination attribution. This daemon has died silently more than once while its
 * status icon stayed green, so every exit now leaves a line in the log: the signal
 * that ended it (TERM from a Stop or a stray kill, HUP, INT), or the fact that the
 * event-tap run loop returned. Only KILL and a crash stay silent, and a crash
 * writes its own report. write(2) is the one async-signal-safe way to say it.
 */
static void on_signal(int sig)
{
	static const char *const names[] = { [SIGHUP] = "HUP", [SIGINT] = "INT", [SIGTERM] = "TERM" };
	char buf[64];
	int n = snprintf(buf, sizeof buf, "buckle: terminated by SIG%s\n",
	    sig < (int)(sizeof names / sizeof names[0]) && names[sig] ? names[sig] : "?");
	if (n > 0) (void)!write(2, buf, (size_t)n);
	_exit(128 + sig);
}

static void attribute_termination(void)
{
	struct sigaction sa = { 0 };
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
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
				audio_list_devices();
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
			case OPT_AUDIO_CHECK:
				/* Open the output (pinned with -d if that came first), prove it
				 * renders on the device it should, print the verdict, and exit. */
				return audio_check(opt_device);
			default:
				usage(argv[0]);
				return 1;
				break;
		}
	}

	if(opt_verbose) {
		open_console();
	}

	attribute_termination();
	fprintf(stderr, "buckle: started, pid %ld\n", (long)getpid());

	/* Path to data files can also be specified by environment, this is
	 * used by the snap package */

	const char *env_path = getenv("BUCKLESPRING_WAV_DIR");
	if (env_path) {
		opt_path_audio = env_path;
	}

	/* Open the output. Without -d the backend follows the system default output
	 * for the life of the process; with -d it stays on the named device. */

	if (audio_open(opt_device) != 0) {
		rv = EXIT_FAILURE;
		goto out;
	}

	printd("Using wav dir: \"%s\"\n", opt_path_audio);

	scan(opt_verbose);
	fprintf(stderr, "buckle: event-tap run loop ended; exiting\n");

out:
	audio_close();

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
		"  -d, --device=DEVICE       pin output to audio device DEVICE (default: follow the\n"
		"                            system default output)\n"
		"  -f, --fallback-sound      use a fallback sound for unknown keys\n"
		"  -g, --gain=GAIN           set playback gain [0..100]\n"
		"  -m, --mute-keycode=CODE   use CODE as mute key (default 0x46 for scroll lock)\n"
		"  -M, --mute                start the program muted\n"
		"  -c, --no-click            don't play a sound on mouse click\n"
		"  -h, --help                show help\n"
		"  -l, --list-devices        list available audio output devices\n"
		"  -p, --audio-path=PATH     load .wav files from directory PATH\n"
		"  -s, --stereo-width=WIDTH  set stereo width [0..100]\n"
		"  -v, --verbose             increase verbosity / debugging\n"
		"      --quiet-from=MIN      start of the quiet-hours window, minutes since midnight\n"
		"      --quiet-to=MIN        end of the quiet-hours window (exclusive); equal to\n"
		"                            --quiet-from (the default) disables the window\n"
		"      --quiet-gain=GAIN     gain [0..100] used inside the window (default 0)\n"
		"      --gain-at=MIN         print the gain a click at MIN would play at, and exit\n"
		"      --audio-check         open the output, verify it renders on the expected\n"
		"                            device, print the verdict, and exit\n",
		exe
       );
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
 * Stereo pan for a key, -1 (left) .. 1 (right). Same geometry as the original
 * OpenAL placement of the source at (-x, 0, z) with z = (100 - width) / 100 in
 * front of the listener: the pan is that source's azimuth over a quarter turn,
 * so width 100 puts every off-centre key hard left or right and width 0 centres all.
 */
static double pan_of(int code)
{
	double x = find_key_loc(code);
	double z = (100 - opt_stereo_width) / 100.0;

	if (opt_stereo_width <= 0 || x == 0) return 0;
	return (x < 0 ? -1 : 1) * atan2(fabs(x), z) / (M_PI / 2);
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
	printd("scancode %d/0x%x", code, code);

	/* Scanner couldn't map this physical key (e.g. Fn/Globe on mac) — drop silently. */
	if (code == 0) return 0;

	if (code == 0xff && opt_no_click) return 0;

	/* Check for mute sequence: ScrollLock down+up+down */

	if (press) {
		handle_mute_key(code == opt_mute_keycode);
	}

	int idx = code + press * 256;

	if(snd[idx] == 0) {

		char fname[256];
		snprintf(fname, sizeof(fname), "%s/%02x-%d.wav", opt_path_audio, wav_code_of(code), press);

		printd("Loading audio file \"%s\"", fname);

		snd[idx] = audio_load(fname);
		if(snd[idx] == 0 && opt_fallback_sound) {
			snprintf(fname, sizeof(fname), "%s/%02x-%d.wav", opt_path_audio, 0x31, press);
			snd[idx] = audio_load(fname);
		}
		if(snd[idx] == 0) {
			snd[idx] = -1;
			return -1;
		}
	}

	if(snd[idx] > 0 && !muted) {
		/* Gain belongs on the PER-PLAY path: it is the quiet window's output, evaluated
		 * against the clock for this click, and the backend applies it to this voice alone. */
		int gain = effective_gain();
		printd("gain %d%% pan %.2f for sample %d", gain, pan_of(code), snd[idx]);
		return audio_play(snd[idx], pan_of(code), gain);
	}

	return 0;
}



/*
 * End
 */
