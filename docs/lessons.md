# Bucklespring lessons

## Menu choices and launch validation need one profile list

A directory-backed profile can disappear after a menu renders. I use `buckle_profile_rows`
for shell rows, native-menu compilation, and `buckle_profile_valid`; a second copied list
would let the menu and action owner disagree. The built-in default stays first. Reject an
unknown or path-shaped profile before stopping the current process. Compile-time metadata
does not authorize a later launch.

Native quiet-hour callbacks leave reopening to their source-validating menu dispatcher.
The plugin still owns parsing, persistence, rejection feedback, and restarting a running
process. Two reopen owners can replace each other's frames or lose the selected row.

## `nohup` does not detach a daemon from its caller's process group

A background `nohup` child still inherited the menu or restore runner's process group. Runner
cleanup could therefore kill Bucklespring several seconds after the one-second launch check had
painted its icon green. Launch through the repository's shared detacher with a new session, closed
descriptors, an exact working directory, and an exact child process identifier. Reconciliation
must stop a live process when intent is disabled and replace it during forced code convergence.

A profile validator must consume the complete shared enumerator even after finding a match.
Returning early closes the process-substitution pipe and turns later producer writes into misleading
broken-pipe errors in the lifecycle log.

## openal-soft cannot follow the macOS default output, and its reopen reports success on failure

Three fixes kept OpenAL and followed the default device from the app: real device names
(`ALC_ALL_DEVICES_SPECIFIER`), then a hand-rolled CoreAudio listener whose name lookup was the
library's cached and stale enumeration, then the library's own `ALC_SOFT_system_events` plus
`alcReopenDeviceSOFT` at the next keystroke. The third passed every software flip between two
connected devices and still went silent when AirPods were put on. openal-soft's CoreAudio backend
pins a HALOutput unit to the device id that was the default at open time, and `alcReopenDeviceSOFT`
documents returning true even when the new device fails to start, leaving a disconnected device
that nothing checked or retried. The unified log shows that reopen failing inside the HAL
(`_StartIO(): Start failed - error 35`) with buckle logging nothing afterwards.

The rule: on macOS use the DefaultOutput AudioUnit, which CoreAudio keeps on the default device
itself, and prove liveness with a render heartbeat rather than a return code. The transition is
what needs verifying, not the steady state: a probe that reopens onto AirPods already streaming
succeeds and proves nothing about pairing. `--audio-check` pins the property the bug violated: the
unit renders, on the device that is the system default.

## A generated pkg-config file with an absolute prefix dies with the directory it names

`setup-macos.sh` wrote `alure.pc` with the checkout's absolute path; after the move from
`plugins/` to `modules/`, `make` could no longer link while `ensure_binary` reported the binary
current, because it rebuilds only when a source is newer. The Mac build now has no generated
files, so a moved or cloned checkout builds with `make` alone.

## A daemon's identity is its pidfile, never its process name

The daemon died silently twice (2026-09-25 21:54, 2026-09-26 02:32) with its pidfile intact and
its icon green. Both `is_running` and teardown asked `pgrep -x buckle`, and so did the plugin
core's declared-daemon sweep. A process name is machine-global: any sandboxed suite that reached
this plugin's reconciler through the resurrect fan-out read no intent from its own server, saw
the production daemon through that name, and tore it down while stopping only its own pidfile.
Eight suites could do it without shimming `pgrep`. Identity is the pidfile now, with the holder's
command line validated against the executable name so a recycled pid cannot pass, and
`test-bucklespring.sh` asserts the live daemon on the machine survives the whole suite. The
daemon also logs every exit (`terminated by SIGTERM`, `run loop ended`), so the next silent death
names its cause.

## A terminal updated in place breaks TCC for everything it launched

The daemon was alive, its icon green, and no key reached it: its log showed the watchdog
re-enabling the event tap every five seconds. `tccd` was logging "Failed to get code reference"
for kitty, the terminal that started this tmux server and therefore the responsible process every
daemon under it inherits. kitty had been running since Sep 12 as 0.48.2 while the bundle on disk
had become 0.49.1 on Sep 24; once TCC re-validated it, every grant attributed to it stopped
applying, and even `osascript` keystrokes were refused. Nothing in this repository can repair that;
only restarting the terminal, then the tmux server under it, does. What the repository can do is
tell the truth: the daemon names the state once in its log, the cell reads it and paints orange,
and the line says which application to restart.
