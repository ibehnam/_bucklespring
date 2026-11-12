# Capture and output

## The keyboard tap

Keyboard capture is a listen-only session tap, which macOS gates on Input Monitoring. TCC checks
the grant of the responsible process: the terminal that started the tmux server, whose identity
every process the server starts inherits. The grant is therefore the terminal's, never
`buckle`'s. When the tap cannot be created, the daemon stays alive, since the grant can land
while it runs: it asks the system once to register the request (`CGRequestListenEventAccess`,
which lists the terminal), writes one line beginning `event tap disabled by the system` that
names the terminal as the application to grant or restart, and retries on its five-second
watchdog, noting `event tap created` once a retry succeeds. A tap the system keeps disabling is
the same failure arriving later, typically after the terminal was updated on disk while running:
after three watchdog re-enables with no event between them, the daemon writes the same line and
keeps retrying quietly, and `event tap receiving events again` marks recovery. The status cell reads those lines from the log tail and
paints a live but deaf daemon orange, never green. The tap also re-enables itself when
WindowServer reports a timeout or user-input disable. This healing lives in the C fork, so the
loaded sound buffers survive it.

A modifier sends `flagsChanged`, which carries no press or release, so each one is read from its
side's own device bit in the event's flags (`NX_DEVICE*KEYMASK`); toggling per event swapped a
key's press and release for good after one missed event. Caps Lock and Fn, which have no bit,
and an event with the generic flag but neither side's bit still toggle.

## The output unit

Audio output on macOS is native CoreAudio (`audio-coreaudio.c`, behind the backend interface in
`buckle.h`): a DefaultOutput AudioUnit, which CoreAudio itself keeps on the system default
output across AirPods pairing, Control Centre switches, hot-plug, and AirPlay. Nothing listens
for device changes; the fork mixes its own voices (constant-power pan from the key's row
position, per-voice gain) into that unit.

The unit runs only while clicks play. Startup creates and initialises it once, stopped (about
130 ms, paid then); a click starts it (3 to 11 ms on the built-in speakers) after checking that
it sits on the default device, since a stopped unit is never trusted to have followed a change,
and it stops 30 seconds after the last click. Each start logs `output on` and each stop
`output off`, and startup logs `output off until a key`, so the icon rests gray between bursts
of typing. Idle therefore means no render thread, no timer, no sleep assertion, and no file
writes. Stopping clears the voices, so a click left over from a stall never plays at the next
start. A start that takes over 150 ms drops its click and the keys queued behind it in the next
50 ms, since a click that late sounds wrong, and names the device once per life; the rule
engages only after a measured slow start. No output device at startup is not fatal: the first
click after one appears builds the unit.

While the unit runs, a 0.5-second run-loop timer checks it: a render counter that has not
advanced for 1.5 seconds is a stall, and a unit off the default device on two consecutive ticks
missed a move. Either, like a failed start, gets the unit rebuilt; a rebuild that does not bring
rendering back doubles the wait before the next, up to five minutes, the first render resets
it, and a new default device ends it at once. Uptime drives every check, so a sleep never reads
as a stall. A stall is two log lines, `output stalled: <why>` and `output recovered`, which the
cell reads as it reads the tap's; the identity thread also writes one when the key thread has
not pulsed for 15 seconds, so a hung daemon still turns yellow. `--audio-check` starts the unit
as a click would, proves it renders on the expected device, stops it, and proves the rendering
stopped; the suite drives it. Reopen only on evidence: never reintroduce an app-side device
listener or a reopen schedule, and never trust a library's success code for a device move (see
[the lessons](lessons/output.md)). OpenAL and ALURE survive only in `audio-openal.c` for Linux and
Windows, which write no stall or output-state line, so the icon there never stalls or rests.

## Quiet hours and gain

Time-varying gain belongs in the fork, on the per-play path: the backend applies the gain to
each click's voice at trigger time, so the quiet window needs no cache invalidation. Keep the
added work off the event-tap callback: skip the clock when the window is disabled, and convert
at most once a minute with the thread-safe call. Quiet dimming is opt-in, with equal bounds
meaning off. The fork exposes the rule for one minute of the day (`--gain-at`, which also reads
a `--settings` file given before it), so the shell suite can prove the C and shell comparisons
agree.

## Files

The pidfile, log, previous log, and settings file live under `~/.cache/tmux-bucklespring/`.
