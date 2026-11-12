> **Structure (hierarchify convention).** This file is a map, not a store: it holds links and invariants, never data. Put new material in the most specific file below; if none fits, create `<topic>.md` (add a `<topic>/` folder when it needs several files). Keep every file under 1000 words. Run `/hierarchify` to restructure.

# Bucklespring lessons

The incidents behind the plugin's rules, by topic.

- [Lifecycle](lessons/lifecycle.md) — one profile list for menus and validation, `nohup` that
  did not detach, and a generated pkg-config file that died with its directory.
- [Output](lessons/output.md) — why openal-soft could not follow the macOS default output, and
  the output unit that ran around the clock until it ran only while clicks play.
- [Identity](lessons/identity.md) — a daemon's identity is its pidfile, never its process name.
- [Permissions](lessons/permissions.md) — a terminal updated in place breaks TCC for everything
  it launched, and the retired LaunchAgent.
