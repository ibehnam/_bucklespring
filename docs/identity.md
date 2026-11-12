# Bucklespring identity

The daemon claims its own pidfile: it opens `~/.cache/tmux-bucklespring/buckle.pid`, takes an
exclusive `flock`, writes its pid, and holds the descriptor for life. A second daemon names the
holder in its log and exits 75. SIGTERM removes the pidfile and exits 0; the script never writes
it. The pidfile is the daemon's only handle: Stop signals that holder alone, after checking its
command line still names `buckle`, and nothing asks or kills by process name
(docs/lessons/daemons/identity.md). The daemon owns its log as well. Once it holds the lock, it
rotates `buckle.log` to `buckle.log.1`, so the line naming the previous exit survives the restart
that follows and a refused second daemon, which reports on the stderr it inherited, never moves
the holder's log aside. Every line starts with its local time, and every exit leaves a line
naming the signal, the ended run loop, or the lost claim.

The daemon watches its claim from a thread: once the pidfile path is gone or names another
file on two checks a second apart, it logs `<path> no longer names this daemon; exiting` and
exits 1, so removing a sandbox ends its daemon. It opens the keyboard and the speakers only for a
pidfile under the account's home, read from the password database; elsewhere, as in every test
sandbox, it logs `holding the claim without the keyboard or the speakers` and holds the claim
inert, still rereading its settings on SIGHUP.
