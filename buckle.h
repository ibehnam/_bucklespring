#ifndef buckle_h
#define buckle_h

int play(int code, int press);
int scan(int verbose);
void printd(const char *fmt, ...);
void open_console(void);

/*
 * Audio backend: audio-coreaudio.c on macOS (a DefaultOutput unit follows the system default
 * output by construction), audio-openal.c everywhere else. Sample handles are > 0; 0 = failure.
 */
int  audio_open(const char *device);                   /* NULL = the system default output */
void audio_close(void);
int  audio_load(const char *path);
int  audio_play(int sample, double pan, int gain_pct);  /* pan -1 (left) .. 1 (right) */
void audio_forget_samples(void);                       /* free every sample; all handles are invalid after */
void audio_monitor(const char *heartbeat_path);        /* output watchdog on the main run loop; NULL = no heartbeat file */
void audio_list_devices(void);
int  audio_check(const char *device);                  /* --audio-check seam: 0 healthy, 1 not, 2 no device */

#endif
