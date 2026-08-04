# Bucklespring

The bucklespring plugin controller owns start/stop, profile, gain, quiet hours, icon state, permission guidance, and rebuilding. Profiles are discovered from sound directories.

Buckle is a detached daemon in the tmux server's process group, not a pane process, so resurrect never relaunches it. `@buckle_enabled`, `@buckle_gain`, `@buckle_profile`, and the two quiet-window bounds ride the shared `resurrect/status-state` companion; after those options are restored, the resurrect hook reconciles the saved intent to process state. The unattended restore path uses an existing executable without opening a build popup.

Launch-time values need a relaunch to change: gain and the quiet window are baked into the daemon's argv, so a user edit persists always and restarts only a running daemon, and never starts a stopped one. Quiet dimming is opt-in here, with equal bounds meaning off, and the quiet level is derived from the shared level set in the shell so only the time comparison exists in C.

Audio-device following belongs in the C fork. It listens for OpenAL default-device events and reopens the live device; do not re-exec the process or trust a mid-process default-device string.

Time-varying gain also belongs in the fork, on the per-play path. Sources are cached per key, so gain set in the source-creation branch is frozen at each key's first press for the process lifetime — that, not a missing flag, is what blocks a clock-driven window. Keep the added work off the event-tap callback: skip the clock when the window is disabled, convert at most once a minute with the thread-safe call, and issue the audio call only on a real change. The fork exposes the rule for one minute-of-day so the shell suite can prove the C and shell comparisons agree.

Keyboard-event-tap healing also belongs in the C fork. The macOS tap is listen-only, re-enables itself when WindowServer reports a timeout or user-input disable, and has a five-second run-loop watchdog for lost disable notifications. Keep this recovery in-process so the loaded sound buffers and other live state survive.

Keyboard capture is a separate macOS TCC permission. Grant Accessibility/Input Monitoring to the responsible terminal process, not the ad-hoc-signed `buckle` binary. A failed event tap produces the orange permission state; deliberate stop clears it. Update icon state before best-effort guidance so a missing client cannot abort the state write.

Logs and the daemon pidfile live under `~/.cache/tmux-bucklespring/`. Rebuild when sources are newer than the binary, not only when the executable is missing.
