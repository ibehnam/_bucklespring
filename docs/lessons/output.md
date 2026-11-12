# Output lessons

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
itself, and prove liveness with its render counter rather than a return code. The transition is
what needs verifying, not the steady state: a probe that reopens onto AirPods already streaming
succeeds and proves nothing about pairing. `--audio-check` pins the property the bug violated: the
unit renders, on the device that is the system default. Reopen only on evidence: the unit is
rebuilt when its render counter stalls or it is proven off the default device twice running,
never on a listener's word or a schedule. (The `render.hb` heartbeat that once published this
is retired; see the next lesson.)

## An output unit left running cost the machine its sleep (2026-11-11)

The DefaultOutput unit started at launch and rendered silence for the daemon's whole life: about
94 render callbacks a second, a `PreventUserIdleSystemSleep` assertion coreaudiod held "Created
for PID" buckle, and a watchdog that rebuilt the unit 198 times in one three-day life, 87% of its
log. Its proof of life, `render.hb`, was renamed into the status daemon's watched directory every
five seconds, and each rename re-rendered the cell. A click needs the unit for a tenth of a
second.

The unit is now created once and left stopped. The first click starts it in 3 to 11 ms on the
built-in speakers, and it stops 30 seconds after the last, so idle means no render thread, no
timer, no assertion, and no writes; a stall became a pair of log lines rather than a file that
ages. A stopped unit is not trusted to follow a device change: the check before each start
rebuilds one off the default device, and a new default ends the rebuild backoff at once. A start
over 150 ms drops its click and the keys queued behind it, a rule that engages only after a
measured slow start. Measure a start on each slow device (Bluetooth, a display's speakers) with
`--audio-check`, which prints it: only a start over 250 ms would justify moving the unit's calls
off the key thread.
