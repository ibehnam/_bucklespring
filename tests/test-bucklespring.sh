#!/usr/bin/env bash
# Bucklespring plugin Layer A menu + lifecycle coverage.
#
# Menu coverage asserts every actionable archetype (profile radio, volume radio, Start/Stop
# toggle) receives the constructor-derived sticky reopen. Lifecycle coverage proves pidfile
# identity, orphan-free profile switches, and init/restore reconciliation without opening a
# build popup.
#
# SEAM: plugin.sh's CLI case has no source-guard (sourcing it would run the case),
# so we run `menu` as a SUBPROCESS behind a display-menu-capturing `tmux` shim (mirrors
# test-notif.sh / test-dashboard.sh). `show_menu` reaches the world only through `tmux show`
# (→ the isolated -L server) and deterministic `pgrep`/fake-buckle shims; nothing real is
# launched or built.

HERE="$(cd "$(dirname "$0")" && pwd)"
TMUX_CONFIG_DIR="${TMUX_CONFIG_DIR:-$(cd "$HERE/../../.." && pwd)}"
export TMUX_CONFIG_DIR
# shellcheck source=AI/tests/lib.sh
. "${TMUX_TESTS_LIB:-$TMUX_CONFIG_DIR/AI/tests/lib.sh}"

BUCKLE="$HERE/../plugin.sh"
REAL_BUCKLE_BIN="$HERE/../buckle"

tsetup
export XDG_CACHE_HOME="$TS_TMP/cache"
cleanup() {
  if [ -f "$BUCKLE_PIDFILE" ]; then
    pid=$(cat "$BUCKLE_PIDFILE" 2>/dev/null) || pid=""
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
  fi
  if [ -f "${BUCKLE_PID_LOG:-}" ]; then
    while read -r pid; do kill -KILL "$pid" 2>/dev/null || true; done < "$BUCKLE_PID_LOG"
  fi
  tteardown
}
trap cleanup EXIT

# shellcheck source=AI/tmux-ui-lib.sh
. "$TMUX_CONFIG_DIR/AI/tmux-ui-lib.sh"   # tmux_quiet_* / tmux_volume_* — the shell half of the parity case

# Capturing tmux shim: capture `display-menu` argv (one per line) to MENU_ARGS,
# record `display-popup` argv (the build popup — an UNATTENDED path must never open one),
# suppress deferred run-shell children, and pass everything else through to the isolated
# -L server.
MENU_ARGS="$TS_TMP/menu.args"; : > "$MENU_ARGS"
POPUP_LOG="$TS_TMP/popup.log"; : > "$POPUP_LOG"
RUN_SHELL_LOG="$TS_TMP/run-shell.log"; : > "$RUN_SHELL_LOG"
cat > "$TS_SHIMDIR/tmux" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = display-menu ]; then
  : > "$MENU_ARGS"
  for a in "\$@"; do printf '%s\n' "\$a" >> "$MENU_ARGS"; done
  exit 0
fi
if [ "\${1:-}" = display-popup ]; then
  printf '%s\n' "\$*" >> "$POPUP_LOG"
  exit 0
fi
if [ "\${1:-}" = run-shell ]; then
  printf '%s\n' "\$*" >> "$RUN_SHELL_LOG"
  exit 0
fi
exec "$REAL_TMUX" -L "$TS_SOCK" "\$@"
SHIM
chmod +x "$TS_SHIMDIR/tmux"

# Deterministic process-liveness shim: fake launches record their own pid, and pgrep reports the
# union of live recorded instances. That makes multiple survivors observable.
BUCKLE_CACHE_DIR="$TS_TMP/buckle-cache"
BUCKLE_PIDFILE="$BUCKLE_CACHE_DIR/buckle.pid"
BUCKLE_LOG="$BUCKLE_CACHE_DIR/buckle.log"
BUCKLE_PID_LOG="$TS_TMP/buckle.pids"
export BUCKLE_CACHE_DIR BUCKLE_PIDFILE BUCKLE_LOG BUCKLE_PID_LOG
cat > "$TS_SHIMDIR/pgrep" <<'SHIM'
#!/usr/bin/env bash
found=1
if [ "${1:-}" = -x ] && [ "${2:-}" = buckle ] && [ -f "$BUCKLE_PID_LOG" ]; then
  while read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then printf '%s\n' "$pid"; found=0; fi
  done < "$BUCKLE_PID_LOG"
fi
exit "$found"
SHIM
chmod +x "$TS_SHIMDIR/pgrep"

# Restore runs a fake stale executable from an env-overridden plugin dir. The
# newer source fixture proves the nobuild path does not invoke display-popup.
FAKE_BUCKLE_DIR="$TS_TMP/bucklespring"
BUCKLE_LAUNCH_LOG="$TS_TMP/buckle.launches"
export BUCKLE_LAUNCH_LOG
mkdir -p "$FAKE_BUCKLE_DIR"
cat > "$FAKE_BUCKLE_DIR/buckle" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BUCKLE_LAUNCH_LOG"
printf '%s\n' "$$" >> "$BUCKLE_PID_LOG"
if [ "${BUCKLE_FAKE_LINGER:-}" = 1 ]; then
  trap 'exit 0' TERM INT
  while :; do sleep 0.2 & wait $!; done
fi
SHIM
chmod +x "$FAKE_BUCKLE_DIR/buckle"
touch -t 202001010000 "$FAKE_BUCKLE_DIR/buckle"
touch -t 202101010000 "$FAKE_BUCKLE_DIR/source.c"

printf '== test-bucklespring.sh ==\n'

launch_count() {
  if [ -f "$BUCKLE_LAUNCH_LOG" ]; then
    wc -l < "$BUCKLE_LAUNCH_LOG" | tr -d ' '
  else
    printf '0'
  fi
}

wait_for_launch() {
  local i=0
  while [ "$i" -lt 50 ] && [ "$(launch_count)" -lt 1 ]; do
    perl -e 'select(undef,undef,undef,0.02)' 2>/dev/null || sleep 1
    i=$((i + 1))
  done
}

live_launch_pids() {
  [ -f "$BUCKLE_PID_LOG" ] || return 0
  while read -r pid; do kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"; done < "$BUCKLE_PID_LOG"
}

live_launch_count() {
  live_launch_pids | sed '/^$/d' | wc -l | tr -d ' '
}

wait_live_count() { # count
  local want="$1" i=0
  while [ "$i" -lt 80 ] && [ "$(live_launch_count)" != "$want" ]; do
    perl -e 'select(undef,undef,undef,0.05)' 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  [ "$(live_launch_count)" = "$want" ]
}

mark_running() {
  clear_running
  sleep 300 &
  printf '%s\n' "$!" >> "$BUCKLE_PID_LOG"
}

clear_running() {
  if [ -f "$BUCKLE_PID_LOG" ]; then
    while read -r pid; do
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done < "$BUCKLE_PID_LOG"
  fi
  rm -f "$BUCKLE_PID_LOG" "$BUCKLE_PIDFILE"
}

# --- The menu is present and every actionable row chains the reopen (sticky) --------
test_menu_sticky() {
  local bdir; bdir="$(cd "$HERE/.." && pwd)"
  local reopen="$bdir/plugin.sh menu -"

  if ! bash "$BUCKLE" menu </dev/null; then
    skip "buckle: \`menu\` did not run (submodule missing?) — cannot assert rows"
    return 0
  fi
  local dump; dump="$(cat "$MENU_ARGS")"

  assert_contains "buckle: title present"                              "$dump" "BUCKLESPRING"
  # Profile radio (the built-in default is always present), volume radio (100 is always a
  # level), and the Start/Stop toggle — each chains `; TMUX_MENU_SELECT=<idx> <self> menu`
  # via tmux_menu_action so the reopened menu keeps its highlight. Only the default profile's
  # index (0) is pinned: the volume/toggle indices shift with the number of wav-klack packs
  # the submodule ships, so those assert the prefix without the number (index math is locked
  # exactly by the notif/awake/name-color/dashboard tests).
  assert_contains "buckle: profile row chains reopen + selection"      "$dump" "start \"default\" ; TMUX_MENU_SELECT=0 $reopen"
  assert_contains "buckle: volume row (100%) chains reopen (sticky)"  "$dump" "gain \"100\" ; TMUX_MENU_SELECT="
  assert_contains "buckle: Start/Stop row chains reopen (sticky)"     "$dump" "toggle ; TMUX_MENU_SELECT="
}

# --- The quiet row: default OFF, and a set window shown + editable ------------
# Buckle's window defaults to off (from == to) — dimming here is opt-in, unlike notif's
# preserved 20:00–07:00 — and the row is the only place it is visible or changeable. The
# prompt round-trip is built entirely by the shared row builder, so this also pins that
# plugin.sh needs no `quiet-edit` subcommand of its own.
test_menu_quiet_row() {
  local bdir; bdir="$(cd "$HERE/.." && pwd)"
  tmux set -gu @buckle_quiet_from 2>/dev/null || true
  tmux set -gu @buckle_quiet_to 2>/dev/null || true
  if ! bash "$BUCKLE" menu </dev/null; then
    skip "buckle: \`menu\` did not run (submodule missing?) — cannot assert the quiet row"
    return 0
  fi
  local dump; dump="$(cat "$MENU_ARGS")"
  assert_contains "buckle quiet: unset window reads off" "$dump" "Quiet hours: off"
  assert_contains "buckle quiet: row carries the prompt round-trip" "$dump" \
    "$TMUX_CONFIG_DIR/AI/tmux-prompt.sh --prompt '$TMUX_QUIET_HINT: ' --initial '' --allow-empty -- set -g @buckle_quiet_input @@VAL@@ @@SEP@@ run-shell -b 'TMUX_MENU_SELECT="
  assert_contains "buckle quiet: commit target is this script"      "$dump" \
    "$bdir/plugin.sh quiet-commit'\""

  # A set window shows itself, and the prompt pre-fills with the same label (which
  # tmux_quiet_parse accepts back verbatim, en dash included).
  tmux set -g @buckle_quiet_from 1200
  tmux set -g @buckle_quiet_to 420
  bash "$BUCKLE" menu </dev/null
  dump="$(cat "$MENU_ARGS")"
  assert_contains "buckle quiet: set window is shown"   "$dump" "Quiet 20:00–07:00"
  assert_contains "buckle quiet: prompt pre-fills with the label" "$dump" "--initial '20:00–07:00'"
  tmux set -gu @buckle_quiet_from 2>/dev/null || true
  tmux set -gu @buckle_quiet_to 2>/dev/null || true
}

# --- quiet-commit: parse → persist → restart a RUNNING buckle -----------------
# The window is baked into buckle's argv at launch (only the time COMPARISON is in C), so a
# live daemon has to be relaunched to learn a new one — do_gain's rule applied to the other
# launch-time value. A stopped buckle must stay stopped, exactly as picking a volume does.
test_quiet_commit_restarts_running() {
  rm -f "$BUCKLE_LAUNCH_LOG"
  mark_running
  tmux set -g @buckle_gain 50
  tmux set -g @buckle_profile default
  tmux set -g @buckle_quiet_input "22:30–06:00"

  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" quiet-commit
  wait_for_launch

  assert_eq "buckle quiet-commit: window parsed to minutes (from)" "1350" \
    "$(tmux show -gqv @buckle_quiet_from)"
  assert_eq "buckle quiet-commit: window parsed to minutes (to)"   "360" \
    "$(tmux show -gqv @buckle_quiet_to)"
  assert_eq "buckle quiet-commit: input placeholder unset again"   "" \
    "$(tmux show -gqv @buckle_quiet_input)"
  assert_eq "buckle quiet-commit: a running buckle is relaunched"  "1" "$(launch_count)"
  # The window reaches the argv; the quiet LEVEL is still derived from TMUX_VOLUME_LEVELS
  # in the shell, so the level domain stays single-sourced.
  assert_contains "buckle quiet-commit: window + floor reach launch argv" \
    "$(cat "$BUCKLE_LAUNCH_LOG" 2>/dev/null)" \
    "-g 50 --quiet-from 1350 --quiet-to 360 --quiet-gain $(tmux_volume_floor)"
  assert_contains "buckle quiet-commit: menu reopen is detached" \
    "$(cat "$RUN_SHELL_LOG")" "plugin.sh' menu -"

  # Junk is refused without disturbing the stored window, and a stopped buckle stays stopped.
  clear_running
  rm -f "$BUCKLE_LAUNCH_LOG"
  tmux set -g @buckle_quiet_input "sometimes"
  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" quiet-commit
  assert_eq "buckle quiet-commit: junk leaves the window intact" "1350" \
    "$(tmux show -gqv @buckle_quiet_from)"
  assert_eq "buckle quiet-commit: a stopped buckle is not started" "0" "$(launch_count)"

  # Empty is a deliberate "off" (--allow-empty), not a cancel.
  mark_running
  tmux set -g @buckle_quiet_input ""
  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" quiet-commit
  wait_for_launch
  assert_eq "buckle quiet-commit: empty commits OFF (from == to)" "0 0" \
    "$(tmux show -gqv @buckle_quiet_from) $(tmux show -gqv @buckle_quiet_to)"
  assert_contains "buckle quiet-commit: off launches inert flags" \
    "$(cat "$BUCKLE_LAUNCH_LOG" 2>/dev/null)" "--quiet-from 0 --quiet-to 0"
  clear_running
}

_assert_pidfile_start_stop_shell() { # shell label
  local shell="$1" label="$2" pid launched
  clear_running
  rm -f "$BUCKLE_LAUNCH_LOG"
  BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" "$shell" "$BUCKLE" start default
  assert_rc0 "buckle daemon ($label): start writes a pidfile" wait_file "$BUCKLE_PIDFILE"
  assert_rc0 "buckle daemon ($label): fake daemon records its pid" wait_file "$BUCKLE_PID_LOG"
  pid=$(cat "$BUCKLE_PIDFILE" 2>/dev/null)
  launched=$(tail -n 1 "$BUCKLE_PID_LOG" 2>/dev/null)
  assert_eq "buckle daemon ($label): pidfile names the fake daemon itself" "$launched" "$pid"
  BUCKLE_DIR="$FAKE_BUCKLE_DIR" "$shell" "$BUCKLE" stop
  assert_rc0 "buckle daemon ($label): stop kills the daemon" wait_dead "$pid"
  assert_rc0 "buckle daemon ($label): no fake instance survives stop" wait_live_count 0
  assert_rc1 "buckle daemon ($label): stop removes the pidfile" test -e "$BUCKLE_PIDFILE"
}

test_pidfile_start_stop() {
  _assert_pidfile_start_stop_shell bash PATH-bash
  _assert_pidfile_start_stop_shell /bin/bash system-bash
}

test_profile_switch_replaces_daemon() {
  clear_running
  rm -f "$BUCKLE_LAUNCH_LOG"
  BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" start "Japanese Black"
  assert_rc0 "buckle switch: first profile has one live daemon" wait_live_count 1
  BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" start "Typewriter"
  assert_rc0 "buckle switch: replacement settles at one live daemon" wait_live_count 1
  assert_eq "buckle switch: exactly two launches occurred" 2 "$(launch_count)"
  assert_contains "buckle switch: survivor uses the new profile" \
    "$(tail -n 1 "$BUCKLE_LAUNCH_LOG")" "-p ./wav-klack/Typewriter/"
  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" stop
  assert_rc0 "buckle switch: final stop leaves no fake" wait_live_count 0
}

test_plugin_round_trip_resumes_intent() {
  local overlay="$TS_TMP/plugins.local"
  clear_running
  rm -f "$BUCKLE_LAUNCH_LOG" "$overlay"
  tmux set -g @buckle_enabled 1
  tmux set -g @buckle_profile default

  BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" TMUX_PLUGINS_LOCAL="$overlay" \
    "$TMUX_CONFIG_DIR/AI/tmux-plugin-lib.sh" set bucklespring on
  assert_rc0 "buckle plugin round-trip: enabled init starts intent" wait_live_count 1
  BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" TMUX_PLUGINS_LOCAL="$overlay" \
    "$TMUX_CONFIG_DIR/AI/tmux-plugin-lib.sh" set bucklespring off
  assert_rc0 "buckle plugin round-trip: master off stops daemon" wait_live_count 0
  assert_eq "buckle plugin round-trip: master off preserves enabled preference" 1 \
    "$(tmux show -gqv @buckle_enabled)"
  BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" TMUX_PLUGINS_LOCAL="$overlay" \
    "$TMUX_CONFIG_DIR/AI/tmux-plugin-lib.sh" set bucklespring on
  assert_rc0 "buckle plugin round-trip: master on resumes daemon via init" wait_live_count 1
  assert_eq "buckle plugin round-trip: preference remains enabled" 1 \
    "$(tmux show -gqv @buckle_enabled)"
  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" teardown
  wait_live_count 0 || true
}

# --- C/shell parity: ONE table, two implementations of the same rule ----------
# in_quiet() in the fork is the design's only duplicated rule; --gain-at is the seam that
# lets this suite prove the two agree instead of assuming it. Self-skipping: the fake-buckle
# shim above cannot answer --gain-at, so this needs a real built binary.
test_gain_at_parity() {
  if [ ! -x "$REAL_BUCKLE_BIN" ] || ! "$REAL_BUCKLE_BIN" --gain-at 0 >/dev/null 2>&1; then
    skip "buckle --gain-at: no built binary with quiet support — C/shell parity unverifiable"
    return 0
  fi
  local gain=100 quiet; quiet="$(tmux_volume_floor)"
  local win now want got bad=""
  for win in "1200 420" "60 300" "0 0" "600 600"; do
    set -- $win
    for now in 0 59 60 299 300 419 420 599 600 601 1199 1200 1400 1439; do
      want="$(TMUX_QUIET_NOW_MIN=$now tmux_volume_effective "$gain" "$1" "$2")"
      got="$("$REAL_BUCKLE_BIN" -g "$gain" --quiet-from "$1" --quiet-to "$2" \
        --quiet-gain "$quiet" --gain-at "$now" 2>/dev/null)"
      [ "$want" = "$got" ] || bad="$bad [$1-$2 @$now: shell=$want c=$got]"
    done
  done
  assert_eq "buckle: --gain-at agrees with tmux_quiet_active over the whole table" "" "$bad"
}

# --- Restore reconciles persisted intent to process state --------------------
test_restore_starts_enabled() {
  clear_running
  rm -f "$BUCKLE_LAUNCH_LOG"
  : > "$POPUP_LOG"
  tmux set -g @buckle_enabled 1
  tmux set -g @buckle_gain 50
  tmux set -g @buckle_profile "Japanese Black"
  tmux set -g @buckle_quiet_from 1200
  tmux set -g @buckle_quiet_to 420

  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" restore
  wait_for_launch

  assert_eq "buckle restore: enabled + stopped launches once" "1" "$(launch_count)"
  assert_contains "buckle restore: saved gain reaches launch argv" \
    "$(cat "$BUCKLE_LAUNCH_LOG" 2>/dev/null)" "-g 50"
  # The restored window rides the same argv — a rebooted server comes back dimming on the
  # user's schedule without any further action.
  assert_contains "buckle restore: saved quiet window reaches launch argv" \
    "$(cat "$BUCKLE_LAUNCH_LOG" 2>/dev/null)" "--quiet-from 1200 --quiet-to 420 --quiet-gain 25"
  # The stale-source fixture would make ensure_binary rebuild; the unattended restore path
  # passes `nobuild`, so no build popup may appear (previously only implied by the fixture).
  assert_eq "buckle restore: unattended path opens no build popup" "" "$(cat "$POPUP_LOG")"
  assert_contains "buckle restore: multi-word profile reaches launch argv" \
    "$(cat "$BUCKLE_LAUNCH_LOG" 2>/dev/null)" "-p ./wav-klack/Japanese Black/"
  assert_eq "buckle restore: saved profile remains intact" \
    "Japanese Black" "$(tmux show -gqv @buckle_profile)"
}

test_restore_keeps_disabled_off() {
  clear_running
  rm -f "$BUCKLE_LAUNCH_LOG"
  tmux set -g @buckle_enabled 0
  tmux set -gu @buckle_icon_color 2>/dev/null || true

  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" restore

  assert_eq "buckle restore: disabled intent launches nothing" "0" "$(launch_count)"
  assert_contains "buckle restore: disabled intent paints the off icon" \
    "$(tmux show -gqv @buckle_icon_color)" "colour196"
}

test_restore_is_idempotent_when_running() {
  rm -f "$BUCKLE_LAUNCH_LOG"
  mark_running
  tmux set -g @buckle_enabled 1
  tmux set -gu @buckle_icon_color 2>/dev/null || true

  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" restore

  assert_eq "buckle restore: already-running daemon is not relaunched" "0" "$(launch_count)"
  assert_contains "buckle restore: already-running daemon paints the on icon" \
    "$(tmux show -gqv @buckle_icon_color)" "colour84"
}

test_menu_sticky
test_menu_quiet_row
test_quiet_commit_restarts_running
test_pidfile_start_stop
test_profile_switch_replaces_daemon
test_plugin_round_trip_resumes_intent
test_gain_at_parity
test_restore_starts_enabled
test_restore_keeps_disabled_off
test_restore_is_idempotent_when_running
finish
