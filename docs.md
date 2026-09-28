> **Structure (hierarchify convention).** This file is a map, not a store: it holds links and invariants, never data. Put new material in the most specific file below; if none fits, create `<topic>.md` (add a `<topic>/` folder when it needs several files). Keep every file under 1000 words. Run `/hierarchify` to restructure.

# Bucklespring plugin

The `bucklespring` plugin owns key sounds: the `buckle` daemon and, on macOS, its LaunchAgent; the sound preferences and their menu; and the key-sound icon, whose producer it owns in the status daemon.

- [Lifecycle](docs/bucklespring.md): the pidfile claim, the supervisor, settings delivery, reconciliation, the icon, and signing.
- [Capture and output](docs/capture.md): the keyboard tap and its permission, the output unit, the heartbeat, and quiet hours.
- [Lessons](docs/lessons.md): the incidents behind the profile list, the detacher, the backend, identity, and permissions.
