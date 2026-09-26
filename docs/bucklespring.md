# Bucklespring

The bucklespring plugin controller owns start/stop, profile, gain, quiet hours, icon state, permission guidance, and rebuilding. Profiles are discovered from sound directories.

`buckle_profile_rows` supplies the ordered profile list to the shell menu, launch validator,
and compiler-only `menu-authority` command. The compiler executes this owner and mirrors its
profiles and absolute pidfile path for native menus. Launch validation runs again when an
action executes, so a removed profile cannot stop the current process and start an invalid
replacement. See [the ownership lessons](lessons.md).

Buckle is launched through the shared `tmux_tmuxd_detach` boundary (the daemon's `detach` verb) in
its own session and process group; when no daemon binary exists yet, it degrades to a plain
background start so a host still building `tmuxd` can launch it regardless. Its lifetime cannot
depend on a transient restore, menu, terminal, or test runner. The
pidfile stores the exact `buckle` process, rather than a shell wrapper, and it is the daemon's only
handle: Stop signals that holder alone, after checking its command line still names `buckle`. Nothing
asks or kills by process name (docs/lessons/daemons/identity.md). Every exit leaves a line in the log,
naming the signal that ended the process or the fact that the event-tap run loop returned.

The status icon is a fact, not a memory of the last start. Where `tmuxd.bucklespring` is on, the
status daemon's `bucklespring` producer computes `@buckle_icon_color` from the pidfile holder's
liveness (a live process named `buckle`): the pidfile directory is a path watch and the holder's
pid an exit watch, so the cell turns red the instant the daemon dies, and orange only while
`@buckle_perm_error` is set. A holder that vanished while its pidfile stayed and intent says on
was killed from outside, so the producer asks `plugin.sh restore` to bring it back, at most once
per thirty seconds; Stop withdraws intent before it kills, and every teardown removes the pidfile
first, so neither triggers it. While the daemon owns the cell this script only announces the
intent options it changed; `plugin.sh icon` remains the byte-for-byte oracle the parity suite
holds the native cell to, and the bash writer stays for hosts whose switch is still off.

`@buckle_enabled`, `@buckle_gain`, `@buckle_profile`, and the quiet-window bounds use the shared state file. `init` reconciles this intent with process state. `restore` calls the same reconciler. A forced plugin convergence replaces an already-running process so new lifecycle code cannot leave an old daemon behind. Both paths use the existing executable and never open a build popup.

Launch-time values need a relaunch to change: gain and the quiet window are baked into the daemon's argv, so a user edit persists always and restarts only a running daemon, and never starts a stopped one. Quiet dimming is opt-in here, with equal bounds meaning off, and the quiet level is derived from the shared level set in the shell so only the time comparison exists in C.

Audio output on macOS is native CoreAudio (`audio-coreaudio.c`, behind the backend interface in
`buckle.h`): a DefaultOutput AudioUnit, which CoreAudio itself keeps on the system default output
device across AirPods pairing, Control Centre switches, hot-plug, and AirPlay. Nothing listens for
device changes and nothing reopens; the fork mixes its own voices (constant-power pan from the
key's row position, per-voice gain) into that unit. OpenAL and ALURE survive only in
`audio-openal.c` for Linux and Windows. A watchdog on the play path rebuilds the unit when the
render counter stops advancing between two plays, or when the unit is provably off the default
device on two consecutive checks. `--audio-check` opens the output silently and reports whether
it renders on the expected device; the test suite drives it. Never reintroduce an app-side
reopen loop or trust a library's success code for a device move (see [lessons](lessons.md)).

Time-varying gain also belongs in the fork, on the per-play path: the backend applies the gain to
each click's voice at trigger time, so the quiet window needs no cache invalidation. Keep the
added work off the event-tap callback: skip the clock when the window is disabled and convert at
most once a minute with the thread-safe call. The fork exposes the rule for one minute-of-day
(`--gain-at`) so the shell suite can prove the C and shell comparisons agree.

Keyboard-event-tap healing also belongs in the C fork. The macOS tap is listen-only, re-enables itself when WindowServer reports a timeout or user-input disable, and has a five-second run-loop watchdog for lost disable notifications. Keep this recovery in-process so the loaded sound buffers and other live state survive.

Keyboard capture is a separate macOS TCC permission. Grant Accessibility/Input Monitoring to the
responsible terminal process, not the ad-hoc-signed `buckle` binary. A tap that cannot be created
produces the orange permission state at start; deliberate stop clears it. A tap the system keeps
disabling is the same failure arriving later: the daemon lives, no key reaches it, and after three
watchdog re-enables with no event between them `scan-mac.m` writes one line, `event tap disabled
by the system`, and keeps retrying quietly; `event tap receiving events again` marks recovery. The
status cell and `plugin.sh icon` read those two lines from the log tail and paint a live but deaf
daemon orange, never green. The usual cause is the terminal that launched tmux being updated on
disk while it kept running: TCC can no longer validate the running app, so every process it
launched loses its grants at once, and only restarting that terminal (and the tmux server under
it) restores them. Update icon state before best-effort guidance so a missing client cannot abort
the state write.

Logs and the daemon pidfile live under `~/.cache/tmux-bucklespring/`; each start keeps the previous life's log once as `buckle.log.1`, so the line naming an exit survives the restart that follows it. The Mac build is `make`
alone: system frameworks, no Homebrew packages, no generated pkg-config files. Rebuild when
sources are newer than the binary, not only when the executable is missing.
