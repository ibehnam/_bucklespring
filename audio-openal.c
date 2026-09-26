/*
 * OpenAL output for Linux and Windows: the upstream bucklespring path, behind the
 * backend interface in buckle.h. macOS uses audio-coreaudio.c instead, because
 * openal-soft's CoreAudio backend pins the device it opened and never follows the
 * system default; PulseAudio and PipeWire move an unpinned stream themselves.
 */
#include <stdio.h>
#include <string.h>
#include <math.h>

#include <AL/al.h>
#include <AL/alc.h>
#include <AL/alure.h>

#include "buckle.h"

#define MAX_SAMPLES 512

static ALCdevice  *device;
static ALCcontext *context;
static ALuint bufs[MAX_SAMPLES + 1], srcs[MAX_SAMPLES + 1];   /* 1-based handles */
static int nsamples;

int audio_open(const char *name)
{
	static const ALfloat ori[] = { 0.0f, 0.0f, 1.0f, 0.0f, 1.0f, 0.0f };

	if (!name) name = alcGetString(NULL, ALC_DEFAULT_ALL_DEVICES_SPECIFIER);
	fprintf(stderr, "buckle: opening OpenAL output device \"%s\"\n", name ? name : "(default)");

	device = alcOpenDevice(name);
	if (!device) {
		fprintf(stderr, "buckle: unable to open audio device\n");
		return -1;
	}
	context = alcCreateContext(device, NULL);
	if (!context || !alcMakeContextCurrent(context)) {
		fprintf(stderr, "buckle: failed to make audio context current\n");
		audio_close();
		return -1;
	}
	(void)alGetError();
	alListener3f(AL_POSITION, 0, 0, 0);
	alListener3f(AL_VELOCITY, 0, 0, 0);
	alListenerfv(AL_ORIENTATION, ori);
	return 0;
}

void audio_close(void)
{
	alcMakeContextCurrent(NULL);
	if (context) { alcDestroyContext(context); context = NULL; }
	if (device)  { alcCloseDevice(device);     device  = NULL; }
}

int audio_load(const char *path)
{
	ALuint buf, src = 0;

	if (nsamples >= MAX_SAMPLES) return 0;
	buf = alureCreateBufferFromFile(path);
	if (buf == 0) {
		fprintf(stderr, "buckle: cannot open \"%s\": %s\n", path, alureGetErrorString());
		return 0;
	}
	alGenSources(1, &src);
	if (alGetError() != AL_NO_ERROR) {
		alDeleteBuffers(1, &buf);
		return 0;
	}
	alSourcei(src, AL_BUFFER, buf);
	(void)alGetError();
	bufs[++nsamples] = buf;
	srcs[nsamples] = src;
	return nsamples;
}

int audio_play(int sample, double pan, int gain_pct)
{
	ALenum err;
	/* Same azimuth as the CoreAudio pan: the listener faces +z, so its right is -x. */
	double theta = pan * M_PI / 2.0;

	if (sample <= 0 || sample > nsamples) return -1;
	alSource3f(srcs[sample], AL_POSITION, (ALfloat)-sin(theta), 0.0f, (ALfloat)cos(theta));
	alSourcef(srcs[sample], AL_GAIN, gain_pct / 100.0f);
	alSourcePlay(srcs[sample]);
	err = alGetError();
	if (err != AL_NO_ERROR) {
		fprintf(stderr, "buckle: playback error 0x%x; dropping click\n", err);
		return -1;
	}
	return 0;
}

void audio_list_devices(void)
{
	const ALCchar *s = alcGetString(NULL, ALC_ALL_DEVICES_SPECIFIER);

	printf("Available audio devices:");
	while (s && *s) {
		printf(" \"%s\"", s);
		s += strlen(s) + 1;
	}
	printf("\n");
}

int audio_check(const char *name)
{
	if (audio_open(name) != 0) return 1;
	printf("device=\"%s\" ok\n", alcGetString(device, ALC_ALL_DEVICES_SPECIFIER));
	audio_close();
	return 0;
}
