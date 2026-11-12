#ifndef buckle_h
#define buckle_h

#include <stdint.h>

int play(int code, int press);
int scan(int verbose);
void printd(const char *fmt, ...);
void open_console(void);

/*
 * main.c's services to the scanner and the backend. The key thread's timers call pulse(), and
 * the identity watch reads a key thread that stops pulsing as a stalled output; only a scanner
 * that pulses is supervised. A stall is two log lines, `output stalled: WHY` and `output
 * recovered`, which the status cell reads; either thread may declare one, for its own cause.
 */
enum { STALL_AUDIO = 1, STALL_KEYS = 2 };
uint64_t uptime_ns(void);                              /* stops while the machine sleeps */
void pulse(void);
void output_stalled(unsigned cause, const char *why);  /* a line for each new cause */
void output_recovered(unsigned cause);                 /* a line once no cause is left */

/*
 * Audio backend: audio-coreaudio.c on macOS (a DefaultOutput unit follows the system default
 * output by construction), audio-openal.c everywhere else. Sample handles are > 0; 0 = failure.
 */
int  audio_open(const char *device);                   /* NULL = the system default output */
void audio_close(void);
int  audio_load(const char *path);
int  audio_play(int sample, double pan, int gain_pct);  /* pan -1 (left) .. 1 (right) */
void audio_forget_samples(void);                       /* free every sample; all handles are invalid after */
void audio_monitor(const char *heartbeat_path);        /* output timer on the main run loop; the argument is retired: NULL */
void audio_list_devices(void);
int  audio_check(const char *device);                  /* --audio-check seam: 0 healthy, 1 not, 2 no device */

#endif
