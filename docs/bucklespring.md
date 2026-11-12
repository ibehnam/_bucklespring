# Bucklespring lifecycle

The plugin controller (`plugin.sh`) owns start and stop, profile, gain, quiet hours, permission guidance, and building. Profiles are discovered from sound directories.

## Profiles and menus

`buckle_profile_rows` supplies the ordered profile list to the shell menu, launch validator,
and compiler-only `menu-authority` command. The compiler executes this owner and mirrors its
profiles and absolute pidfile path for native menus. Validation runs again when an action
executes, so a removed profile can never become the daemon's setting. See [the lessons](lessons/lifecycle.md).

## Identity

The daemon claims, logs, and guards its own identity; see [identity](identity.md).

## Launch

The script launches the daemon through the shared detacher (`tmux_tmuxd_detach`) on every
platform: its own session and process group, no inherited descriptors, and a lifetime that never
depends on whether the start came from a menu, a restore, an SSH session, or a test runner. On
macOS the tmux server is that launch's ancestor, so the daemon's responsible process is the
terminal that started the server, and that terminal's Input Monitoring grant covers the keyboard
tap. `buckle` holds no grant, signature, or LaunchAgent of its own ([capture](capture.md),
[lessons](lessons/permissions.md)). The launch passes `--mute-keycode 0`: the daemon drops code 0 before its
mute check, so no double-tapped key can silence it under a green icon.

## Settings

Gain, quiet hours, and profile reach the daemon through one settings file beside the pidfile.
The script reads the five preferences with one tmux call; a read that returns none changes
nothing, so a server that did not answer never reads as "off". It writes the file compare-first
from the durable preferences and announces a change with
SIGHUP; the daemon applies it at the next click and reloads samples when the profile changed. A
preference therefore never restarts the daemon and never starts a stopped one. The quiet level
is derived from the shared level set in the shell, so only the time comparison exists in C.

## Reconciliation

`init`, `attach`, and `restore` share one reconciler, and a native menu choice reaches it
through core's `converge`, which runs the `attach` hook under the plugin lifecycle lock. It
rewrites the settings. With intent on, it launches a stopped daemon,
relaunches one whose binary is newer than its claim or whose claim is older than the running
server, and otherwise signals a changed setting. The second rule exists because a detached
daemon outlives its server while its grant stays with that server's terminal: after the terminal
and tmux restart, the new server's reconciler replaces the deaf survivor.
With intent off, it stops a daemon that still runs, and reports one that survives SIGTERM. No
supervisor watches the process, so the reconciler at attach is what restarts a dead daemon; the
icon turns red the moment one dies, and the doctor warns while intent is on and no daemon runs,
with the plugin log's last lines, since a failed start says why only there.
Unattended paths never open a build popup: they rebuild a binary older than its sources quietly
into `build.log`. Every launch requires a current binary, because the daemon's argv contract
moves with its sources.

## Icon

The icon is the status daemon's `bucklespring` producer on every host, computed from facts; the
script never writes it. A live holder is green. A live holder whose keyboard tap the system
refuses is orange, from the daemon's own log line. A live, enabled holder whose latest output
line is `output stalled: <why>` is yellow, until `output recovered` or a fresh start. One whose
latest output-state line is `output off` is gray, the house colour for idle: on macOS the
output rests until a key, and the daemon logs `output off until a key` at startup and
`output on` and `output off` at each start and stop ([capture](capture.md)); Linux logs neither
and stays green. Orange stays the refused tap's alone, because the menu and the doctor match
that form. Anything else is red. The pidfile directory is a path watch, the pidfile and log are
leaf watches, and the holder's pid an exit watch, so the cell turns red the instant the daemon
dies. The menu's Input Monitoring row and the doctor read the published icon rather than parse
the log a second time; the doctor also faults a live holder whose log says it is inert, which
the icon shows green. `modules/tmuxd/src/cells/bucklespring.rs` holds the rules, and
`AI/tests/modules/test-tmuxd-parity.sh` pins them against goldens.

## Building

The Mac build is `make` alone: system frameworks, no Homebrew packages, no generated pkg-config
files, and no signature beyond the linker's ad-hoc one, because the grant belongs to the
terminal and a rebuild therefore never asks for it again. Rebuild when sources are newer than the
binary, not only when the executable is missing.
