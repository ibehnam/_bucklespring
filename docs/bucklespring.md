# Bucklespring lifecycle

The plugin controller (`plugin.sh`) owns start and stop, profile, gain, quiet hours, permission guidance, building, and signing. Profiles are discovered from sound directories.

## Profiles and menus

`buckle_profile_rows` supplies the ordered profile list to the shell menu, launch validator,
and compiler-only `menu-authority` command. The compiler executes this owner and mirrors its
profiles and absolute pidfile path for native menus. Validation runs again when an action
executes, so a removed profile can never become the daemon's setting. See [the lessons](lessons.md).

## Identity

The daemon claims its own pidfile: it opens `~/.cache/tmux-bucklespring/buckle.pid`, takes an
exclusive `flock`, writes its pid, and holds the descriptor for life. A second daemon names the
holder in its log and exits 75. SIGTERM removes the pidfile and exits 0; the script never writes
it. The pidfile is the daemon's only handle: Stop signals that holder alone, after checking its
command line still names `buckle`, and nothing asks or kills by process name
(docs/lessons/daemons/identity.md). The daemon owns its log as well. Once it holds the lock, it
rotates `buckle.log` to `buckle.log.1`, so the line naming the previous exit survives the restart
that follows and a refused second daemon, which reports on the stderr it inherited, never moves
the holder's log aside. Every exit leaves a line naming the signal or the ended run loop.

## Supervision

On macOS the daemon is a LaunchAgent, `com.behnam.bucklespring`, rendered from
`launchd/com.behnam.bucklespring.plist.in` into `~/Library/LaunchAgents`. `KeepAlive` restarts a
crash and never a clean exit, `ThrottleInterval` spaces restarts five seconds apart, and
`RunAtLoad` starts it at login while it is enabled. Start enables and bootstraps it, or kickstarts
a loaded one; Stop, teardown, and purge boot it out and disable it, so it also stays down at the
next login. Purge then removes the plist, a `durable` manifest row. The agent is machine-global,
so only the checkout the running server loaded may manage it (`tmux_server_runs_checkout`): a
suite's isolated server or a second checkout never reaches `launchctl`. On Linux the script
launches the daemon through the shared detacher, in its own session and process group.

## Settings

Gain, quiet hours, and profile reach the daemon through one settings file beside the pidfile.
The script writes it compare-first from the durable preferences and announces a change with
SIGHUP; the daemon applies it at the next click and reloads samples when the profile changed. A
preference therefore never restarts the daemon and never starts a stopped one. The quiet level
is derived from the shared level set in the shell, so only the time comparison exists in C.

## Reconciliation

`init`, `attach`, and `restore` share one reconciler, and the native menu reaches it through
core's forced apply. It rewrites the settings. With intent on, it launches a stopped daemon,
relaunches one whose binary is newer than its claim, hands a daemon launchd never loaded over to
the agent, and otherwise signals a changed setting. With intent off, it stops a daemon that still
runs. Linux has no supervisor, so the reconciler at attach is what restarts a dead daemon there.
Unattended paths never open a build popup: they rebuild a binary older than its sources quietly
into `build.log`. Every launch requires a current binary, because the daemon's argv contract
moves with its sources, and a binary that refused it would restart under launchd every five
seconds.

## Icon

The icon is the status daemon's `bucklespring` producer on every host, computed from facts; the
script never writes it. A live holder is green. A live holder whose keyboard tap the system
refuses is orange, from the daemon's own log line. A live, enabled holder whose `render.hb`
heartbeat is older than fifteen seconds is yellow. Anything else is red. The pidfile directory is
a path watch and the holder's pid an exit watch, so the cell turns red the instant the daemon
dies. The menu's Input Monitoring row and the doctor read the published icon rather than parse
the log a second time. `modules/tmuxd/src/cells/bucklespring.rs` holds the rules, and
`AI/tests/test-tmuxd-parity.sh` pins them against goldens.

## Building and signing

The Mac build is `make` alone: system frameworks, no Homebrew packages, no generated pkg-config
files. Rebuild when sources are newer than the binary, not only when the executable is missing.
Under launchd the Input Monitoring grant belongs to `buckle` itself and is keyed on its
signature, and an ad-hoc signature changes with every build, so each rebuild would ask again.
`plugin.sh sign-identity` creates a self-signed code-signing identity in the login keychain once
per host; trusting it asks for an administrator, and codesign may ask once for the key. `_build`
then signs a copy with it and renames the copy into place, so a running daemon's executable is
untouched. Without the identity the doctor says that rebuilds prompt again.
