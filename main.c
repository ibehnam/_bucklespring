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
#include <fcntl.h>
#include <stdatomic.h>
#include <sysexits.h>
#include <sys/file.h>
#include <sys/stat.h>

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

/* The daemon's own identity, log and settings (see pidfile_claim, log_to, settings_load). */
static const char *opt_log = NULL;
static const char *opt_pidfile = NULL;
static const char *opt_settings = NULL;
static int opt_claim_only = 0;

/* Long-only options: values above the char range so they can't collide with short_opts. */
enum {
	OPT_QUIET_FROM = 256,
	OPT_QUIET_TO,
	OPT_QUIET_GAIN,
	OPT_GAIN_AT,
	OPT_AUDIO_CHECK,
	OPT_LOG,
	OPT_PIDFILE,
	OPT_SETTINGS,
	OPT_CLAIM_ONLY,
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
	{ "log",            required_argument, NULL, OPT_LOG },
	{ "pidfile",        required_argument, NULL, OPT_PIDFILE },
	{ "settings",       required_argument, NULL, OPT_SETTINGS },
	{ "claim-only",     no_argument,       NULL, OPT_CLAIM_ONLY },
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
 * Lines from the argv parse (a settings load, a log that would not open) wait until this
 * life's first line, `buckle: started`, is out: the status cell and plugin.sh read that
 * line as the marker that opens a life, and holding them also lands them in this life's
 * log whatever the argv order. A one-shot mode, or an exit before the start, releases them;
 * a refused claim drops them, because no life starts and its stderr may be the holder's log.
 */
static char held[8192];
static size_t held_len;
static bool holding = true;

static void release_held(void)
{
	holding = false;
	if (held_len) fwrite(held, 1, held_len, stderr);
	held_len = 0;
}

/* One log line: held before the start, straight to stderr after it. */
static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...)
{
	char line[PATH_MAX + 256];
	va_list va;
	int n;

	va_start(va, fmt);
	n = vsnprintf(line, sizeof line, fmt, va);
	va_end(va);
	if (n <= 0) return;
	if ((size_t)n >= sizeof line) {
		n = sizeof line - 1;
		line[n - 1] = '\n';
	}
	if (!holding)
		fwrite(line, 1, (size_t)n, stderr);
	else if (held_len + (size_t)n <= sizeof held) {
		memcpy(held + held_len, line, (size_t)n);
		held_len += (size_t)n;
	}
}


/*
 * --log PATH: this life's stderr, opened only once the pidfile is claimed, so an instance
 * that is refused never moves the holder's log. The previous life's file is kept once as
 * PATH.1. Only a regular file is moved aside. A log that will not open leaves the inherited
 * stderr in place.
 */
static void log_to(const char *path)
{
	char old[PATH_MAX];
	struct stat st;
	int fd, n;

	if (lstat(path, &st) == 0 && S_ISREG(st.st_mode)) {
		n = snprintf(old, sizeof old, "%s.1", path);
		if (n < 0 || (size_t)n >= sizeof old)
			say("buckle: cannot keep the previous log of %s: %s\n", path, strerror(ENAMETOOLONG));
		else if (rename(path, old) != 0)
			say("buckle: cannot keep the previous log as %s: %s\n", old, strerror(errno));
	}
	fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
	if (fd < 0) {
		say("buckle: cannot open the log %s: %s; logging to the inherited stderr\n", path, strerror(errno));
		return;
	}
	if (fd != STDERR_FILENO) {
		if (dup2(fd, STDERR_FILENO) < 0) {
			say("buckle: cannot log to %s: %s; logging to the inherited stderr\n", path, strerror(errno));
			close(fd);
			return;
		}
		close(fd);
	}
	setvbuf(stderr, NULL, _IONBF, 0);
}


/*
 * --pidfile PATH: the daemon's identity, claimed before the life starts. An exclusive
 * flock, held for the life of the process, lets one buckle own a pidfile at a time; any
 * other exits EX_TEMPFAIL (75). The lock lives on the inode that was opened, so a path
 * unlinked or replaced between the open and the lock (a holder removing it on its way out)
 * is opened again. Only the holder removes the file, and only while the path still names
 * its inode. A failed claim writes its one line straight to the inherited stderr, since
 * --log opens only after the claim, so nothing of the holder's is moved.
 */
#define CLAIM_ATTEMPTS 5

static char claimed_path[PATH_MAX];              /* read by the signal handlers */
static volatile sig_atomic_t claimed_fd = -1;    /* the locked descriptor, once claimed */

/* Async-signal-safe: fstat, stat and unlink only. */
static void pidfile_release(void)
{
	struct stat mine, named;

	if (claimed_fd < 0) return;
	if (fstat(claimed_fd, &mine) == 0 && stat(claimed_path, &named) == 0
	    && mine.st_dev == named.st_dev && mine.st_ino == named.st_ino)
		unlink(claimed_path);
}

/* 0 once PATH holds this pid under our lock; otherwise the exit status, after one line. */
static int pidfile_claim(const char *path)
{
	struct stat mine, named;
	char pid[24];
	ssize_t w;
	int fd, n, err;

	if (strlen(path) >= sizeof claimed_path) {
		fprintf(stderr, "buckle: cannot claim %s: %s\n", path, strerror(ENAMETOOLONG));
		return EXIT_FAILURE;
	}
	for (int attempt = 0; attempt < CLAIM_ATTEMPTS; attempt++) {
		fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
		if (fd < 0) {
			fprintf(stderr, "buckle: cannot claim %s: %s\n", path, strerror(errno));
			return EXIT_FAILURE;
		}
		if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
			err = errno;
			close(fd);
			if (err == EWOULDBLOCK) {
				fprintf(stderr, "buckle: another holder owns %s; exiting\n", path);
				return EX_TEMPFAIL;
			}
			fprintf(stderr, "buckle: cannot claim %s: %s\n", path, strerror(err));
			return EXIT_FAILURE;
		}
		if (fstat(fd, &mine) != 0 || stat(path, &named) != 0
		    || mine.st_dev != named.st_dev || mine.st_ino != named.st_ino) {
			close(fd);   /* locked a file the path no longer names: open the one it names now */
			continue;
		}

		memcpy(claimed_path, path, strlen(path) + 1);
		atomic_signal_fence(memory_order_seq_cst);   /* the path is whole before a handler can see the fd */
		claimed_fd = fd;

		n = snprintf(pid, sizeof pid, "%ld\n", (long)getpid());
		err = 0;
		if (ftruncate(fd, 0) != 0)
			err = errno;
		else if ((w = pwrite(fd, pid, (size_t)n, 0)) != n)
			err = w < 0 ? errno : EIO;
		if (err) {
			fprintf(stderr, "buckle: cannot write %s: %s\n", path, strerror(err));
			pidfile_release();
			return EXIT_FAILURE;
		}
		return 0;
	}
	fprintf(stderr, "buckle: %s was replaced %d times during the claim; giving up\n", path, CLAIM_ATTEMPTS);
	return EXIT_FAILURE;
}


/*
 * Signals. This daemon has died silently more than once while its status icon stayed
 * green, so TERM (a Stop, a teardown, a stray kill) and INT end the life with a line naming
 * them, and remove the pidfile they hold. KILL and a crash stay silent, and a crash writes
 * its own report. HUP no longer ends anything: it asks for the settings file again, which
 * play() rereads at the next key event. The handlers use only async-signal-safe calls.
 */
static volatile sig_atomic_t reload_requested;

static void on_stop(int sig)
{
	static const char term[] = "buckle: terminated by SIGTERM\n";
	static const char intr[] = "buckle: terminated by SIGINT\n";

	if (sig == SIGTERM) (void)!write(STDERR_FILENO, term, sizeof term - 1);
	else                (void)!write(STDERR_FILENO, intr, sizeof intr - 1);
	pidfile_release();
	_exit(sig == SIGTERM ? 0 : 130);
}

static void on_reload(int sig)
{
	(void)sig;
	reload_requested = 1;
}

static void install_signals(void)
{
	struct sigaction sa;

	memset(&sa, 0, sizeof sa);
	sa.sa_flags = SA_RESTART;
	sigemptyset(&sa.sa_mask);
	sigaddset(&sa.sa_mask, SIGTERM);
	sigaddset(&sa.sa_mask, SIGINT);
	sa.sa_handler = on_stop;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sa.sa_handler = on_reload;
	sigaction(SIGHUP, &sa, NULL);
}


/*
 * --settings PATH: the plugin's durable preferences in the daemon's own hands, so a
 * change needs a SIGHUP rather than a relaunch. Strict KEY=VALUE lines, never evaluated:
 * blank lines and # comments are skipped; a line that is not KEY=VALUE, an unknown key,
 * or a malformed or out-of-range value is reported by line number and changes nothing.
 * Keys: gain and quiet_gain (0..100), quiet_from and quiet_to (minutes since midnight,
 * 0..1439), and profile, the sound pack: `default` for the built-in PATH_AUDIO, or a
 * directory name under ./wav-klack/, the same mapping the plugin's -p argument used.
 * Values are never echoed into the log: the status cell searches it for fixed markers.
 */
#define PROFILE_MAX 200   /* a pack name is shorter than this, in bytes */

static char profile_dir[PATH_MAX];   /* opt_path_audio's storage once a settings file chose it */

/* A decimal integer in [lo, hi]: digits only, no sign, space or suffix. */
static bool parse_int(const char *s, int lo, int hi, int *out)
{
	long v = 0;

	if (!*s) return false;
	for (; *s; s++) {
		if (*s < '0' || *s > '9' || v > hi) return false;
		v = v * 10 + (*s - '0');
	}
	if (v < lo || v > hi) return false;
	*out = (int)v;
	return true;
}

/* The sample directory profile NAME selects, into BUF; false for a name that is not a pack. */
static bool profile_path(const char *name, char *buf, size_t size)
{
	size_t len = strlen(name);
	int n;

	if (strcmp(name, "default") == 0)
		n = snprintf(buf, size, "%s", PATH_AUDIO);
	else if (len == 0 || len >= PROFILE_MAX || strchr(name, '/') || !strcmp(name, ".") || !strcmp(name, ".."))
		return false;
	else
		n = snprintf(buf, size, "./wav-klack/%s", name);
	return n >= 0 && (size_t)n < size;
}

/* The profile name of the sample directory in use: profile_path read backwards. */
static const char *profile_name(void)
{
	static const char klack[] = "./wav-klack/";

	if (strcmp(opt_path_audio, PATH_AUDIO) == 0) return "default";
	if (strncmp(opt_path_audio, klack, sizeof klack - 1) == 0) return opt_path_audio + sizeof klack - 1;
	return opt_path_audio;
}

/* One line of F into BUF, without its newline: 1 for a line, 0 at the end of the file, and
 * -1 for a line too long for BUF or holding a NUL byte (consumed, never returned). */
static int settings_line(FILE *f, char *buf, size_t size)
{
	size_t n = 0;
	int c, bad = 0;

	while ((c = getc(f)) != EOF && c != '\n') {
		if (c == '\0' || n + 1 >= size) bad = 1;
		else buf[n++] = (char)c;
	}
	if (c == EOF && n == 0 && !bad) return 0;
	buf[n] = '\0';
	return bad ? -1 : 1;
}

/* Apply the settings file PATH over the current values; true when the sample directory changed. */
static bool settings_load(const char *path)
{
	static const struct { const char *key; int *value; int max; } ints[] = {
		{ "gain",       &opt_gain,       100 },
		{ "quiet_from", &opt_quiet_from, 1439 },
		{ "quiet_to",   &opt_quiet_to,   1439 },
		{ "quiet_gain", &opt_quiet_gain, 100 },
	};
	char line[512], dir[PATH_MAX], before[PATH_MAX];
	int lineno = 0, rc, v;
	size_t i, len;
	FILE *f = fopen(path, "r");

	if (!f) {
		say("buckle: settings: cannot read %s: %s; keeping the current values\n", path, strerror(errno));
		return false;
	}
	snprintf(before, sizeof before, "%s", opt_path_audio);
	while ((rc = settings_line(f, line, sizeof line)) != 0) {
		char *key = line, *value, *p;

		lineno++;
		if (rc < 0) {
			say("buckle: settings: line %d is too long or not text; ignored\n", lineno);
			continue;
		}
		len = strlen(line);
		if (len > 0 && line[len - 1] == '\r') line[--len] = '\0';
		for (p = line; *p == ' ' || *p == '\t'; p++)
			;
		if (*p == '\0' || *p == '#') continue;
		if (!(value = strchr(line, '='))) {
			say("buckle: settings: line %d is not KEY=VALUE; ignored\n", lineno);
			continue;
		}
		*value++ = '\0';

		for (i = 0; i < sizeof ints / sizeof ints[0] && strcmp(key, ints[i].key) != 0; i++)
			;
		if (i < sizeof ints / sizeof ints[0]) {
			if (parse_int(value, 0, ints[i].max, &v))
				*ints[i].value = v;
			else
				say("buckle: settings: line %d: %s must be a whole number 0..%d; keeping %d\n",
				    lineno, ints[i].key, ints[i].max, *ints[i].value);
		} else if (strcmp(key, "profile") == 0) {
			if (!profile_path(value, dir, sizeof dir))
				say("buckle: settings: line %d: profile is not a sound-pack name; keeping %s\n",
				    lineno, profile_name());
			else if (strcmp(dir, opt_path_audio) != 0) {
				memcpy(profile_dir, dir, strlen(dir) + 1);
				opt_path_audio = profile_dir;
			}
		} else {
			say("buckle: settings: line %d: unknown key; ignored\n", lineno);
		}
	}
	if (ferror(f))   /* errno is still the failed read's: nothing has run since it */
		say("buckle: settings: cannot read all of %s: %s; kept the lines before it\n", path, strerror(errno));
	fclose(f);
	say("buckle: settings: gain %d, quiet %d-%d at %d, profile %s\n",
	    opt_gain, opt_quiet_from, opt_quiet_to, opt_quiet_gain, profile_name());
	return strcmp(before, opt_path_audio) != 0;
}

/*
 * SIGHUP's work, run by play() on the key-event thread, so it never races a click: reread
 * the settings file, and when the sound pack changed, drop every loaded sample and every
 * cached handle, so the new pack loads lazily, key by key, like the first one did.
 */
static void settings_reload(void)
{
	if (!opt_settings) {
		say("buckle: SIGHUP without --settings; nothing to reload\n");
		return;
	}
	if (settings_load(opt_settings)) {
		audio_forget_samples();
		memset(snd, 0, sizeof snd);
	}
}

/* <dirname of the pidfile>/render.hb, the audio heartbeat beside the identity it belongs to. */
static const char *heartbeat_path(char *buf, size_t size)
{
	const char *slash;
	int dir, n;

	if (!opt_pidfile) return NULL;
	slash = strrchr(opt_pidfile, '/');
	dir = slash ? (int)(slash - opt_pidfile) + 1 : 0;
	n = snprintf(buf, size, "%.*srender.hb", dir, opt_pidfile);
	return n >= 0 && (size_t)n < size ? buf : NULL;
}


int main(int argc, char **argv)
{
	int c;
	int rv;
	int idx;
	char hb[PATH_MAX];

	/* Lines held by the parse still reach stderr on every exit before the start. */
	atexit(release_held);

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
				release_held();
				usage(argv[0]);
				return 0;
			case 'l':
				release_held();
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
				 * agree. Reads the gain options, and any --settings file, parsed
				 * BEFORE it on the argv. */
				release_held();
				printf("%d\n", gain_at(atoi(optarg)));
				return 0;
			case OPT_AUDIO_CHECK:
				/* Open the output (pinned with -d if that came first), prove it
				 * renders on the device it should, print the verdict, and exit. */
				release_held();
				return audio_check(opt_device);
			case OPT_LOG:
				/* Opened after the claim; a one-shot mode never touches it. */
				opt_log = optarg;
				break;
			case OPT_PIDFILE:
				opt_pidfile = optarg;
				break;
			case OPT_SETTINGS:
				/* Loaded now, so a later --gain-at sees it and a later flag overrides it. */
				opt_settings = optarg;
				settings_load(optarg);
				break;
			case OPT_CLAIM_ONLY:
				opt_claim_only = 1;
				break;
			default:
				usage(argv[0]);
				return 1;
				break;
		}
	}

	if (opt_claim_only && !opt_pidfile) {
		say("buckle: --claim-only needs --pidfile\n");
		return 2;
	}

	if(opt_verbose) {
		open_console();
	}

	/* Claim the identity before the life starts: a second buckle ends here, with its one
	 * line on the inherited stderr and the holder's log where it was. The handlers go
	 * first, so a TERM during the claim still ends it. Only then is the log moved aside
	 * and opened, so `started` is the first line of the fresh one. */
	install_signals();
	if (opt_pidfile && (rv = pidfile_claim(opt_pidfile)) != 0) {
		held_len = 0;   /* no life started: its parse-time lines are dropped, not released */
		return rv;
	}
	if (opt_log)
		log_to(opt_log);

	fprintf(stderr, "buckle: started, pid %ld\n", (long)getpid());

	if (opt_claim_only) {
		/* The test suite's seam: this identity and these signals, with no audio and no
		 * tap. TERM and INT end it through their handlers; HUP only interrupts pause(). */
		fprintf(stderr, "buckle: claim-only; holding %s\n", opt_pidfile);
		release_held();
		for (;;)
			pause();
	}
	release_held();

	/* Path to data files can also be specified by environment, this is
	 * used by the snap package */

	const char *env_path = getenv("BUCKLESPRING_WAV_DIR");
	if (env_path) {
		opt_path_audio = env_path;
	}

	/* Open the output. Without -d the backend follows the system default output
	 * for the life of the process; with -d it stays on the named device. Either
	 * failure below is the daemon's own: the pidfile goes, the icon turns red, and the
	 * plugin's reconciler starts a new life at the next attach. */

	if (audio_open(opt_device) != 0) {
		pidfile_release();
		rv = EXIT_FAILURE;
		goto out;
	}
	audio_monitor(heartbeat_path(hb, sizeof hb));

	printd("Using wav dir: \"%s\"\n", opt_path_audio);

	scan(opt_verbose);
	fprintf(stderr, "buckle: event-tap run loop ended; exiting\n");
	pidfile_release();
	rv = EXIT_FAILURE;

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
		"                            device, print the verdict, and exit\n"
		"      --log=PATH            write stderr to PATH (after the --pidfile claim, if any),\n"
		"                            keeping the previous file as PATH.1\n"
		"      --pidfile=PATH        claim PATH (an exclusive lock holding this pid) before\n"
		"                            starting; exit 75 while another process holds it. The\n"
		"                            audio heartbeat, render.hb, is written beside it\n"
		"      --settings=PATH       read KEY=VALUE lines: gain, quiet_from, quiet_to,\n"
		"                            quiet_gain, and profile (default, or a directory under\n"
		"                            ./wav-klack); SIGHUP rereads PATH at the next key\n"
		"      --claim-only          claim --pidfile and wait for a signal: no audio, no keys\n",
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
	/* A SIGHUP since the last event: the settings apply from this click on. Otherwise
	 * this costs one load of the flag. */
	if (reload_requested) {
		reload_requested = 0;
		settings_reload();
	}

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
