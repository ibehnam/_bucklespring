# Identity lessons

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
