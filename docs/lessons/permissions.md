# Permission lessons

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

## A LaunchAgent traded a rare failure for permanent costs

For one day (2026-09-27 to 2026-09-28) buckle ran as a LaunchAgent, its own responsible process,
so that no terminal update could revoke its grant. The price was a second grant, keyed on
buckle's code signature, which the linker's ad-hoc signature changes at every build; each rebuild
asked for Input Monitoring again. Keeping it required a self-signed identity in every host's
login keychain, a signing step, and a machine-global job that only the checkout the running
server loaded could manage. None of it bought anything the terminal's grant did not already give.

The daemon again launches detached from the tmux server and borrows the terminal's grant. The
in-place update above remains a failure the repository reports rather than prevents. Restarting
the terminal, then tmux, repairs it: the new server relaunches the deaf survivor, whose claim
predates it. The rule: prefer the grant the user already gave; a rare failure the icon names
costs less than a second identity on every host.
