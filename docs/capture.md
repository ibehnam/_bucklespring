# Capture and output

## The keyboard tap

Keyboard capture is a listen-only session tap, which macOS gates on Input Monitoring. Under the
LaunchAgent the grant belongs to `buckle` itself, never to a terminal. When the tap cannot be
created, the daemon stays alive rather than exiting into launchd's restart loop: it asks the
system once to register it (`CGRequestListenEventAccess`), writes one line beginning `event tap
disabled by the system`, and retries on its five-second watchdog, noting `event tap created`
once a retry succeeds. A tap the system keeps
disabling is the same failure arriving later: after three watchdog re-enables with no event
between them, the daemon writes the same line and keeps retrying quietly, and `event tap
receiving events again` marks recovery. The status cell reads those lines from the log tail and
paints a live but deaf daemon orange, never green. The tap also re-enables itself when
WindowServer reports a timeout or user-input disable. This healing lives in the C fork, so the
loaded sound buffers survive it.

## The output unit

Audio output on macOS is native CoreAudio (`audio-coreaudio.c`, behind the backend interface in
`buckle.h`): a DefaultOutput AudioUnit, which CoreAudio itself keeps on the system default
output across AirPods pairing, Control Centre switches, hot-plug, and AirPlay. Nothing listens
for device changes; the fork mixes its own voices (constant-power pan from the key's row
position, per-voice gain) into that unit. A 0.5-second run-loop timer is the watchdog: it
rebuilds the unit when the render counter has not advanced for 1.5 seconds, or when the unit is
off the default device on two consecutive ticks, so a device move heals within a second without
waiting for a keystroke. A rebuild that does not bring rendering back doubles the wait before the
next, up to five minutes, and the first render resets it, so a dead output cannot flood the log.
Uptime drives the stall check, so a sleep never reads as a stall.

The same timer renames `render.hb` (`<renders> <epoch>`) into place beside the pidfile every five
seconds while the counter advances, at once when rendering resumes, and never while it is
stalled; the cell paints a heartbeat older than fifteen seconds yellow. `--audio-check` opens the
output silently and reports whether it renders on the expected device; the suite drives it.
Reopen only on evidence: never reintroduce an app-side device listener or a reopen schedule,
and never trust a library's success code for a device move (see [the lessons](lessons.md)).
OpenAL and ALURE survive only in `audio-openal.c` for Linux and Windows, which write no
heartbeat, so the icon there never stalls.

## Quiet hours and gain

Time-varying gain belongs in the fork, on the per-play path: the backend applies the gain to
each click's voice at trigger time, so the quiet window needs no cache invalidation. Keep the
added work off the event-tap callback: skip the clock when the window is disabled, and convert
at most once a minute with the thread-safe call. Quiet dimming is opt-in, with equal bounds
meaning off. The fork exposes the rule for one minute of the day (`--gain-at`, which also reads
a `--settings` file given before it), so the shell suite can prove the C and shell comparisons
agree.

## Files

The pidfile, log, previous log, settings file, and heartbeat live under
`~/.cache/tmux-bucklespring/`.
