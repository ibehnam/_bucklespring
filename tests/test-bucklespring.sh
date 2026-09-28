#!/usr/bin/env bash
# Bucklespring plugin menu + lifecycle coverage.
#
# Menu coverage asserts every actionable archetype (profile radio, volume radio, Running
# toggle) receives the constructor-derived sticky reopen. Lifecycle coverage proves the
# daemon's own pidfile claim, settings delivered by SIGHUP instead of a relaunch, the
# detached launch every platform shares, and init/restore reconciliation without a build
# popup.
#
# SEAM: plugin.sh's CLI case has no source-guard (sourcing it would run the case),
# so we run `menu` as a SUBPROCESS behind a display-menu-capturing `tmux` shim (mirrors
# test-notif.sh / test-dashboard.sh). `show_menu` reaches the world only through `tmux show`
# (→ the isolated -L server), and every process question goes through THIS suite's pidfile
# (BUCKLE_PIDFILE under its own cache root) and a fake buckle; nothing real is launched or
# built. There is deliberately no `pgrep` shim: identity is the pidfile, so the production
# daemon on this machine is invisible here by construction, and the suite proves that.
#
# LANE: integration
# BUDGET: 30

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMUX_CONFIG_DIR="${TMUX_CONFIG_DIR:-$(cd "$HERE/../../.." && pwd)}"
export TMUX_CONFIG_DIR
# shellcheck source=AI/tests/lib.sh
. "${TMUX_TESTS_LIB:-$TMUX_CONFIG_DIR/AI/tests/lib.sh}"

BUCKLE="$HERE/../plugin.sh"
REAL_BUCKLE_BIN="$HERE/../buckle"

tsetup
export XDG_CACHE_HOME="$TS_TMP/cache"
export XDG_STATE_HOME="$TS_TMP/state"
# The committed defaults, not this machine's overlay: every compile here re-reads the
# plugin layers (docs/testing.md).
export TMUX_PLUGINS_MACHINE_CONFIG="$TS_TMP/plugins.machine"
: > "$TMUX_PLUGINS_MACHINE_CONFIG"
# quiet-commit persists through the native `tmuxd preferences` setter, which resolves its
# server from TMUXD_SOCKET_ARGS (the tmux shim below never rewrites `tmuxd`). Pin it to the
# isolated server and seed its state store and allowlist, or every write lands on the live
# server while the assertions read this one (docs/testing.md).
PERSIST="$TMUX_CONFIG_DIR/AI/tmux-status-persist.sh"
export TMUXD_BIN="${TMUXD_TEST_BIN:-$TMUX_CONFIG_DIR/modules/tmuxd/target/release/tmuxd}"
export TMUXD_SOCKET_ARGS="-L $TS_SOCK"
gtimeout 2m "$TMUXD_BIN" state init
gtimeout 2m bash "$PERSIST" bootstrap
tmux set -g @plugin_preference_options "$(bash "$PERSIST" preference-names | tr '\n' ' ')"
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

# Fake launches record their own pid in BUCKLE_PID_LOG, so multiple survivors stay observable.
BUCKLE_CACHE_DIR="$TS_TMP/buckle-cache"
BUCKLE_PIDFILE="$BUCKLE_CACHE_DIR/buckle.pid"
BUCKLE_LOG="$BUCKLE_CACHE_DIR/buckle.log"
BUCKLE_SETTINGS="$BUCKLE_CACHE_DIR/settings"
BUCKLE_PID_LOG="$TS_TMP/buckle.pids"
BUCKLE_HUP_LOG="$TS_TMP/buckle.hups"
export BUCKLE_CACHE_DIR BUCKLE_PIDFILE BUCKLE_LOG BUCKLE_SETTINGS BUCKLE_PID_LOG BUCKLE_HUP_LOG
# The live daemons on this machine, if any: the suite must leave every one of them alive.
PRODUCTION_BUCKLE_PIDS="$(pgrep -x buckle 2>/dev/null | tr '\n' ' ')"

# A fake daemon with the real one's contract: it writes its own pidfile (the claim),
# removes it on TERM, and records every SIGHUP instead of dying. Its binary is current
# (its one source is older), so only the case that ages it exercises a build.
FAKE_BUCKLE_DIR="$TS_TMP/bucklespring"
BUCKLE_LAUNCH_LOG="$TS_TMP/buckle.launches"
export BUCKLE_LAUNCH_LOG
mkdir -p "$FAKE_BUCKLE_DIR"
mkdir -p "$FAKE_BUCKLE_DIR/wav-klack/Japanese Black" "$FAKE_BUCKLE_DIR/wav-klack/Typewriter"
cat > "$FAKE_BUCKLE_DIR/buckle" <<'SHIM'
#!/usr/bin/env bash
# mark_running starts this fake as a stand-in for an already-live daemon; that start is
# not a launch the plugin made, so it must not count as one.
[ -n "${BUCKLE_FAKE_MARK:-}" ] || printf '%s\n' "$*" >> "$BUCKLE_LAUNCH_LOG"
printf '%s\n' "$$" >> "$BUCKLE_PID_LOG"
pidfile=""
while [ "$#" -gt 0 ]; do [ "$1" = --pidfile ] && pidfile=$2; shift; done
[ -z "$pidfile" ] || printf '%s\n' "$$" > "$pidfile"
if [ "${BUCKLE_FAKE_LINGER:-}" = 1 ]; then
  trap '[ -z "$pidfile" ] || rm -f "$pidfile"; exit 0' TERM INT
  trap 'printf "%s\n" "$$" >> "$BUCKLE_HUP_LOG"' HUP
  # sleep: hold — stay alive (killable) until the test tears the fake down
  while :; do sleep 0.2 & wait $!; done
fi
SHIM
chmod +x "$FAKE_BUCKLE_DIR/buckle"
touch -t 202001010000 "$FAKE_BUCKLE_DIR/buckle"
touch -t 201901010000 "$FAKE_BUCKLE_DIR/source.c"

printf '== test-bucklespring.sh ==\n'

launch_count() {
  if [ -f "$BUCKLE_LAUNCH_LOG" ]; then
    wc -l < "$BUCKLE_LAUNCH_LOG" | tr -d ' '
  else
    printf '0'
  fi
}

hup_count() {
  if [ -f "$BUCKLE_HUP_LOG" ]; then wc -l < "$BUCKLE_HUP_LOG" | tr -d ' '; else printf '0'; fi
}

wait_for_launch() {
  local i=0
  while [ "$i" -lt 50 ] && [ "$(launch_count)" -lt 1 ]; do
    perl -e 'select(undef,undef,undef,0.02)' 2>/dev/null || sleep 1 # sleep: guard — retry tick; the 50-try cap pins the bound
    i=$((i + 1))
  done
}

wait_hups() { # count
  local i=0
  while [ "$i" -lt 50 ] && [ "$(hup_count)" -lt "$1" ]; do
    perl -e 'select(undef,undef,undef,0.02)' 2>/dev/null || sleep 1 # sleep: guard — retry tick; the 50-try cap pins the bound
    i=$((i + 1))
  done
  [ "$(hup_count)" -ge "$1" ]
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
    perl -e 'select(undef,undef,undef,0.05)' 2>/dev/null || sleep 1 # sleep: guard — retry tick; the 80-try cap pins the bound
    i=$((i + 1))
  done
  [ "$(live_launch_count)" = "$want" ]
}

mark_running() {
  clear_running
  # The lingering fake IS the live instance and claims the pidfile itself: is_running
  # validates the holder's command line against the executable name.
  mkdir -p "$BUCKLE_CACHE_DIR"
  BUCKLE_FAKE_MARK=1 BUCKLE_FAKE_LINGER=1 "$FAKE_BUCKLE_DIR/buckle" --pidfile "$BUCKLE_PIDFILE" &
  printf '%s\n' "$!" >> "$BUCKLE_PID_LOG"
  wait_file "$BUCKLE_PIDFILE" || true
}

clear_running() {
  if [ -f "$BUCKLE_PID_LOG" ]; then
    while read -r pid; do
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done < "$BUCKLE_PID_LOG"
  fi
  rm -f "$BUCKLE_PID_LOG" "$BUCKLE_PIDFILE" "$BUCKLE_HUP_LOG" "$BUCKLE_SETTINGS"
}

settings() { cat "$BUCKLE_SETTINGS" 2>/dev/null; }

# --- Native authority: one owner enumerates and validates profiles ------------
test_native_menu_authority() {
  local authority option value profiles="" pidfile="" dir name validation_stderr validation_rc=0
  authority="$(bash "$BUCKLE" menu-authority)"
  while IFS=$'\t' read -r option value; do
    [ -n "$option" ] || continue
    case "$option" in
      @menu_buckle_profiles) profiles="$value" ;;
      @menu_buckle_pidfile) pidfile="$value" ;;
    esac
  done <<< "$authority"
  assert_contains "buckle authority: default profile is exported" "$profiles" $'default\tIBM Model-M'
  case "$pidfile" in /*) value=1 ;; *) value=0 ;; esac
  assert_eq "buckle authority: pidfile is absolute" 1 "$value"
  assert_rc0 "buckle authority: default profile validates" bash "$BUCKLE" profile-valid default
  validation_stderr="$(bash "$BUCKLE" profile-valid 'Japanese Black' 2>&1 >/dev/null)" \
    || validation_rc=$?
  assert_eq "buckle authority: matching profile validates after consuming the registry" 0 "$validation_rc"
  assert_eq "buckle authority: matching profile emits no broken-pipe diagnostic" "" "$validation_stderr"
  while IFS= read -r dir; do
    name=${dir##*/}
    assert_rc0 "buckle authority: discovered profile validates ($name)" \
      bash "$BUCKLE" profile-valid "$name"
  done < <(find "$HERE/../wav-klack" -mindepth 1 -maxdepth 1 -type d | sort)
  assert_rc1 "buckle authority: obsolete profile is refused" \
    bash "$BUCKLE" profile-valid '__obsolete_profile__'

  # Compiler executes the owner and copies precisely its two values.  It must
  # not invent a Rust-side directory scan or a cache-path default.
  "$TMUX_CONFIG_DIR/AI/tmux-plugin-lib.sh" compile
  assert_eq "buckle authority: compiler mirrors profiles from owner" "$profiles" \
    "$(tmux show -gqv @menu_buckle_profiles)"
  assert_eq "buckle authority: compiler mirrors resolved pidfile from owner" "$pidfile" \
    "$(tmux show -gqv @menu_buckle_pidfile)"
}

# --- The menu is present and every actionable row chains the reopen (sticky) --------
test_menu_sticky() {
  local bdir; bdir="$(cd "$HERE/.." && pwd)"
  local reopen="$bdir/plugin.sh menu -"

  if ! TMUX_MENU_RETAIN_PARENT=1 TMUX_MENU_INTERACTIVE=1 \
    bash "$BUCKLE" menu </dev/null; then
    skip "buckle: \`menu\` did not run (submodule missing?) — cannot assert rows"
    return 0
  fi
  local dump; dump="$(cat "$MENU_ARGS")"

  assert_contains "buckle: title present"                              "$dump" "BUCKLESPRING"
  assert_contains "buckle: default profile uses constructor-owned tag join" \
    "$dump" "IBM Model-M  (default)"
  # Profile radio (the built-in default is always present), volume radio (100 is always a
  # level), and the Running toggle each chain the interactive update marker, selection, and reopen
  # via tmux_menu_action so the reopened menu keeps its highlight. Only the default profile's
  # index (0) is pinned: the volume/toggle indices shift with the number of wav-klack packs
  # the submodule ships, so those assert the prefix without the number (index math is locked
  # exactly by the notif/awake/name-color/dashboard tests).
  assert_contains "buckle: profile row chains reopen + selection"      "$dump" "start \"default\" ; TMUX_MENU_UPDATE=1 TMUX_MENU_SELECT=0 $reopen"
  assert_contains "buckle: volume row (100%) chains reopen (sticky)"  "$dump" "gain \"100\" ; TMUX_MENU_UPDATE=1 TMUX_MENU_SELECT="
  assert_contains "buckle: Running row chains reopen (sticky)"        "$dump" "toggle ; TMUX_MENU_UPDATE=1 TMUX_MENU_SELECT="
  assert_contains "buckle: daemon toggle is the Running checkbox"     "$dump" "Running"
  assert_not_contains "buckle: the retired Start verb toggle is gone" "$dump" $'\nStart\n'
  assert_not_contains "buckle: the retired Stop verb toggle is gone"  "$dump" $'\nStop\n'
}

# --- The permission row follows the daemon's published verdict ----------------
# The status cell is the one judge of a refused keyboard tap; the menu offers the Input
# Monitoring pane only while the published icon is the permission form.
test_menu_permission_row() {
  tmux set -gu @buckle_icon_color
  bash "$BUCKLE" menu </dev/null
  assert_not_contains "buckle permission: no row without a refused tap" "$(cat "$MENU_ARGS")" "Input Monitoring"
  tmux set -g @buckle_icon_color "${TMUX_ORANGE}${TMUX_BUCKLE_ICON}${TMUX_RESET}"
  bash "$BUCKLE" menu </dev/null
  assert_contains "buckle permission: a refused tap offers the pane" "$(cat "$MENU_ARGS")" "Input Monitoring → open Settings"
  assert_contains "buckle permission: the row opens the pane" "$(cat "$MENU_ARGS")" "open-perms"
  tmux set -g @buckle_icon_color "${TMUX_GREEN}${TMUX_BUCKLE_ICON}${TMUX_RESET}"
  bash "$BUCKLE" menu </dev/null
  assert_not_contains "buckle permission: a running icon hides it" "$(cat "$MENU_ARGS")" "Input Monitoring"
  tmux set -gu @buckle_icon_color
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
    "$TMUX_CONFIG_DIR/AI/tmux-prompt.sh --history quiet-hours --context"
  assert_contains "buckle quiet: prompt uses the literal-value executable path" "$dump" \
    "--allow-empty --exec -- /usr/bin/env TMUX_MENU_SELECT="
  assert_contains "buckle quiet: commit target is this script"      "$dump" \
    "$bdir/plugin.sh quiet-commit --value @@VAL@@"

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

# --- quiet-commit: parse → persist → the settings file → SIGHUP ---------------
# The daemon rereads its settings file on SIGHUP, so a live daemon learns a new window
# without a relaunch; a stopped one stays stopped, exactly as picking a volume does.
test_quiet_commit_signals_running() {
  rm -f "$BUCKLE_LAUNCH_LOG"
  mark_running
  tmux set -g @buckle_gain 50
  tmux set -g @buckle_profile default
  tmux set -g @buckle_quiet_input "22:30–06:00"

  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" quiet-commit

  assert_eq "buckle quiet-commit: window parsed to minutes (from)" "1350" \
    "$(tmux show -gqv @buckle_quiet_from)"
  assert_eq "buckle quiet-commit: window parsed to minutes (to)"   "360" \
    "$(tmux show -gqv @buckle_quiet_to)"
  assert_eq "buckle quiet-commit: input placeholder unset again"   "" \
    "$(tmux show -gqv @buckle_quiet_input)"
  # The quiet LEVEL is still derived from TMUX_VOLUME_LEVELS in the shell, so the level
  # domain stays single-sourced.
  assert_eq "buckle quiet-commit: window + floor reach the settings file" \
    "gain=50 quiet_from=1350 quiet_to=360 quiet_gain=$(tmux_volume_floor) profile=default" \
    "$(settings | tr '\n' ' ' | sed 's/ $//')"
  assert_rc0 "buckle quiet-commit: the live daemon is told to reread" wait_hups 1
  assert_eq "buckle quiet-commit: and is never relaunched" "0" "$(launch_count)"
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
  assert_eq "buckle quiet-commit: empty commits OFF (from == to)" "0 0" \
    "$(tmux show -gqv @buckle_quiet_from) $(tmux show -gqv @buckle_quiet_to)"
  assert_contains "buckle quiet-commit: off reaches the settings file" "$(settings)" $'quiet_from=0\nquiet_to=0'
  clear_running
}

# --- gain: a new volume is a settings change, never a start -------------------
test_gain_signals_running() {
  rm -f "$BUCKLE_LAUNCH_LOG"
  mark_running
  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" gain 25
  assert_contains "buckle gain: the level reaches the settings file" "$(settings)" "gain=25"
  assert_rc0 "buckle gain: the live daemon is told to reread" wait_hups 1
  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" gain 25
  assert_eq "buckle gain: an unchanged level signals nothing" "1" "$(hup_count)"
  clear_running
  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" gain 50
  assert_eq "buckle gain: a stopped buckle is not started" "0" "$(launch_count)"
  tmux set -g @buckle_gain 100
}

_assert_pidfile_start_stop_shell() { # shell label
  local shell="$1" label="$2" pid launched pgid
  clear_running
  rm -f "$BUCKLE_LAUNCH_LOG"
  BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" "$shell" "$BUCKLE" start default
  assert_rc0 "buckle daemon ($label): the daemon claims its pidfile" wait_file "$BUCKLE_PIDFILE"
  assert_rc0 "buckle daemon ($label): fake daemon records its pid" wait_file "$BUCKLE_PID_LOG"
  pid=$(cat "$BUCKLE_PIDFILE" 2>/dev/null)
  launched=$(tail -n 1 "$BUCKLE_PID_LOG" 2>/dev/null)
  assert_eq "buckle daemon ($label): pidfile names the fake daemon itself" "$launched" "$pid"
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  assert_eq "buckle daemon ($label): launch owns an isolated process group" "$pid" "$pgid"
  assert_contains "buckle daemon ($label): the daemon gets its log, pidfile, and settings" \
    "$(cat "$BUCKLE_LAUNCH_LOG")" "--log $BUCKLE_LOG --pidfile $BUCKLE_PIDFILE --settings $BUCKLE_SETTINGS"
  BUCKLE_DIR="$FAKE_BUCKLE_DIR" "$shell" "$BUCKLE" stop
  assert_rc0 "buckle daemon ($label): stop kills the daemon" wait_dead "$pid"
  assert_rc0 "buckle daemon ($label): no fake instance survives stop" wait_live_count 0
  assert_rc1 "buckle daemon ($label): stop removes the pidfile" test -e "$BUCKLE_PIDFILE"
}

test_pidfile_start_stop() {
  _assert_pidfile_start_stop_shell bash PATH-bash
  _assert_pidfile_start_stop_shell /bin/bash system-bash
}

test_profile_switch_signals_the_daemon() {
  clear_running
  rm -f "$BUCKLE_LAUNCH_LOG"
  BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" start "Japanese Black"
  assert_rc0 "buckle switch: first profile has one live daemon" wait_live_count 1
  assert_contains "buckle switch: the profile reaches the settings file" "$(settings)" "profile=Japanese Black"
  BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" start "Typewriter"
  assert_rc0 "buckle switch: the running daemon is told to reread" wait_hups 1
  assert_eq "buckle switch: exactly one launch occurred" 1 "$(launch_count)"
  assert_rc0 "buckle switch: still one live daemon" wait_live_count 1
  assert_contains "buckle switch: the new profile is in the settings file" "$(settings)" "profile=Typewriter"
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

# --- The settings file the shell writes is the one the daemon reads -----------
# The same rule through the other door: the plugin projects the preferences into the
# settings file, and the real binary's --gain-at reads it back.
test_settings_reach_the_binary() {
  if [ ! -x "$REAL_BUCKLE_BIN" ] || ! "$REAL_BUCKLE_BIN" --settings /dev/null --gain-at 0 >/dev/null 2>&1; then
    skip "buckle --settings: no built binary with settings support"
    return 0
  fi
  clear_running
  tmux set -g @buckle_gain 50 \; set -g @buckle_quiet_from 60 \; set -g @buckle_quiet_to 120
  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" gain 50
  assert_eq "buckle settings: inside the window the binary plays the floor" "$(tmux_volume_floor)" \
    "$("$REAL_BUCKLE_BIN" --settings "$BUCKLE_SETTINGS" --gain-at 90 2>/dev/null)"
  assert_eq "buckle settings: outside it, the gain" "50" \
    "$("$REAL_BUCKLE_BIN" --settings "$BUCKLE_SETTINGS" --gain-at 200 2>/dev/null)"
  tmux set -g @buckle_gain 100 \; set -gu @buckle_quiet_from \; set -gu @buckle_quiet_to
}

# --- The daemon's claim: one holder per pidfile -------------------------------
# The real binary claims the pidfile under an exclusive lock: a second daemon names the
# holder and exits 75, and TERM ends the holder cleanly and removes the pidfile.
test_claim_is_exclusive() {
  local dir pid rc=0
  if [ ! -x "$REAL_BUCKLE_BIN" ] || ! "$REAL_BUCKLE_BIN" --help 2>&1 | rg -q -- '--claim-only'; then
    skip "buckle --claim-only: no built binary with the claim"
    return 0
  fi
  dir="$TS_TMP/claim"; mkdir -p "$dir"
  "$REAL_BUCKLE_BIN" --log "$dir/buckle.log" --pidfile "$dir/buckle.pid" --claim-only &
  pid=$!
  assert_rc0 "buckle claim: the holder writes its pid" wait_file_contains "$dir/buckle.pid" "$pid"
  assert_rc0 "buckle claim: and starts its own log" wait_file_contains "$dir/buckle.log" "buckle: started, pid $pid"
  # A refused daemon touches nothing: it says so on the stderr it inherited and never
  # rotates the holder's log aside.
  gtimeout 10s "$REAL_BUCKLE_BIN" --log "$dir/buckle.log" --pidfile "$dir/buckle.pid" --claim-only \
    2>"$dir/second.err" || rc=$?
  assert_eq "buckle claim: a second daemon exits 75" 75 "$rc"
  assert_contains "buckle claim: and names the holder's pidfile on its stderr" "$(cat "$dir/second.err")" \
    "buckle: another holder owns $dir/buckle.pid"
  assert_contains "buckle claim: the holder's log stays in place" "$(cat "$dir/buckle.log")" \
    "buckle: started, pid $pid"
  assert_rc1 "buckle claim: and is never rotated by the refused daemon" test -e "$dir/buckle.log.1"
  assert_eq "buckle claim: the pidfile still names the first holder" "$pid" "$(cat "$dir/buckle.pid")"
  kill -HUP "$pid"
  perl -e 'select(undef,undef,undef,0.2)' # sleep: hold — give a wrongly fatal HUP time to land
  assert_rc0 "buckle claim: SIGHUP rereads, it never ends the holder" kill -0 "$pid"
  kill -TERM "$pid"; rc=0; wait "$pid" || rc=$?
  assert_eq "buckle claim: TERM is a clean exit" 0 "$rc"
  assert_rc1 "buckle claim: and removes the pidfile" test -e "$dir/buckle.pid"
}

# --- The output backend: renders, and on the device it should -----------------
# --audio-check opens the real output silently (no click), proves the render callback runs,
# and that the unit sits on the system default output — the property the whole "headphones
# on, no clicks" family of bugs violated. Self-skipping without a built binary; rc 2 means the
# host has no output device at all (a headless box), which is not a defect of the backend.
test_audio_check() {
  local out rc=0
  if [ ! -x "$REAL_BUCKLE_BIN" ]; then
    skip "buckle --audio-check: no built binary — output backend unverifiable"
    return 0
  fi
  out="$(gtimeout 20s "$REAL_BUCKLE_BIN" --audio-check 2>/dev/null)" || rc=$?
  if [ "$rc" = 2 ]; then
    skip "buckle --audio-check: no output device on this host"
    return 0
  fi
  assert_eq "buckle --audio-check: output renders on the system default device" 0 "$rc"
  assert_contains "buckle --audio-check: verdict names the device" "$out" 'device="'
  assert_contains "buckle --audio-check: verdict is ok" "$out" " ok"
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
  # The restored window rides the settings file: a rebooted server comes back dimming on
  # the user's schedule without any further action.
  assert_eq "buckle restore: saved preferences reach the settings file" \
    "gain=50 quiet_from=1200 quiet_to=420 quiet_gain=25 profile=Japanese Black" \
    "$(settings | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "buckle restore: unattended path opens no build popup" "" "$(cat "$POPUP_LOG")"
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
  assert_eq "buckle restore: the plugin never writes the icon" "" "$(tmux show -gqv @buckle_icon_color)"
}

test_restore_stops_disabled_running() {
  rm -f "$BUCKLE_LAUNCH_LOG"
  mark_running
  tmux set -g @buckle_enabled 0

  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" restore

  assert_rc0 "buckle restore: disabled intent stops a live daemon" wait_live_count 0
  assert_eq "buckle restore: disabling launches no replacement" "0" "$(launch_count)"
}

test_restore_is_idempotent_when_running() {
  rm -f "$BUCKLE_LAUNCH_LOG"
  mark_running
  tmux set -g @buckle_enabled 1

  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" restore
  assert_eq "buckle restore: already-running daemon is not relaunched" "0" "$(launch_count)"
  assert_rc0 "buckle restore: a first settings file is announced" wait_hups 1
  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" restore
  assert_eq "buckle restore: current settings signal nothing" "1" "$(hup_count)"
  clear_running
}

# A forced convergence (core's apply after every native menu choice) restarts a live
# daemon only for new code: a binary newer than the holder's claim.
test_forced_restore_restarts_only_new_code() {
  rm -f "$BUCKLE_LAUNCH_LOG"
  mark_running
  tmux set -g @buckle_enabled 1
  tmux set -g @buckle_gain 50

  TMUX_PLUGIN_FORCE_CONVERGE=1 BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" \
    bash "$BUCKLE" restore
  assert_eq "buckle forced restore: current code is never relaunched" "0" "$(launch_count)"

  touch -t 203001010000 "$FAKE_BUCKLE_DIR/buckle"
  TMUX_PLUGIN_FORCE_CONVERGE=1 BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" \
    bash "$BUCKLE" restore
  assert_rc0 "buckle forced restore: new code settles at one daemon" wait_live_count 1
  assert_eq "buckle forced restore: new code relaunches once" "1" "$(launch_count)"
  touch -t 202001010000 "$FAKE_BUCKLE_DIR/buckle"
  clear_running
  tmux set -g @buckle_gain 100
}

# A detached daemon outlives the server that started it, and its keyboard grant stays with
# that server's terminal. A claim older than this server is relaunched once, and the new
# claim settles it. The stamp sits between the fake binary's (2020) and the server's start,
# so only the server rule can fire.
test_restore_relaunches_a_previous_servers_holder() {
  rm -f "$BUCKLE_LAUNCH_LOG"
  mark_running
  tmux set -g @buckle_enabled 1
  touch -t 202101010000 "$BUCKLE_PIDFILE"
  BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" restore
  assert_rc0 "buckle restore: another server's holder settles at one daemon" wait_live_count 1
  assert_eq "buckle restore: and is relaunched once" "1" "$(launch_count)"
  BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" restore
  assert_eq "buckle restore: this server's own holder is left alone" "1" "$(launch_count)"
  clear_running
}

# An unattended reconcile never opens a popup and never launches a binary older than its
# sources, because the daemon's argv contract moves with them. The build runs quietly into
# its log.
test_unattended_build_is_quiet() {
  local err="$TS_TMP/restore.err"
  clear_running
  rm -f "$BUCKLE_LAUNCH_LOG" "$TS_TMP/make.log" "$BUCKLE_CACHE_DIR/build.log"
  : > "$POPUP_LOG"
  tmux set -g @buckle_enabled 1
  touch -t 202101010000 "$FAKE_BUCKLE_DIR/source.c"
  printf '#!/usr/bin/env bash\nprintf "make ran\\n" >> "%s"\nprintf "no rule\\n"\nexit 2\n' "$TS_TMP/make.log" > "$TS_SHIMDIR/make"
  chmod +x "$TS_SHIMDIR/make"
  BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" restore 2>"$err"
  assert_contains "unattended build: a stale binary is rebuilt" "$(cat "$TS_TMP/make.log" 2>/dev/null)" "make ran"
  assert_eq "unattended build: one that stays stale is never launched" 0 "$(launch_count)"
  assert_contains "unattended build: and the refusal says why" "$(cat "$err")" "older than its sources"
  assert_contains "unattended build: the build output lands in its log" \
    "$(cat "$BUCKLE_CACHE_DIR/build.log" 2>/dev/null)" "no rule"
  printf '#!/usr/bin/env bash\ntouch "%s/buckle"\n' "$FAKE_BUCKLE_DIR" > "$TS_SHIMDIR/make"
  BUCKLE_FAKE_LINGER=1 BUCKLE_DIR="$FAKE_BUCKLE_DIR" bash "$BUCKLE" restore
  wait_for_launch
  assert_eq "unattended build: a successful build launches once" 1 "$(launch_count)"
  assert_eq "unattended build: never through a popup" "" "$(cat "$POPUP_LOG")"
  rm -f "$TS_SHIMDIR/make"
  touch -t 202001010000 "$FAKE_BUCKLE_DIR/buckle"
  touch -t 201901010000 "$FAKE_BUCKLE_DIR/source.c"
  clear_running
}

test_failed_build_popup_holds_and_preserves_rc() {
  local fail_dir="$TS_TMP/failing build" output rc
  mkdir -p "$fail_dir"
  printf '#!/usr/bin/env bash\nprintf "build failed visibly\\n"\nexit 7\n' > "$TS_SHIMDIR/make"
  chmod +x "$TS_SHIMDIR/make"
  output=$(printf q | bash "$BUCKLE" build-popup "$fail_dir" 2>&1); rc=$?
  assert_eq "buckle build popup: failed build rc survives the hold" "7" "$rc"
  assert_contains "buckle build popup: failure output remains readable" \
    "$output" "build failed visibly"
  assert_contains "buckle build popup: failure still reaches the any-key hold" \
    "$output" "press any key to close"
  rm -f "$TS_SHIMDIR/make"
}

test_native_menu_authority
test_menu_sticky
test_menu_permission_row
test_menu_quiet_row
test_quiet_commit_signals_running
test_gain_signals_running
test_pidfile_start_stop
test_profile_switch_signals_the_daemon
test_plugin_round_trip_resumes_intent
test_gain_at_parity
test_settings_reach_the_binary
test_claim_is_exclusive
test_audio_check
test_restore_starts_enabled
test_restore_keeps_disabled_off
test_restore_stops_disabled_running
test_restore_is_idempotent_when_running
test_forced_restore_restarts_only_new_code
test_restore_relaunches_a_previous_servers_holder
test_unattended_build_is_quiet
test_failed_build_popup_holds_and_preserves_rc

# --- Isolation: this suite never touches the machine's live daemon ------------
# Twice a sandboxed suite reached bucklespring's reconciler, read no intent from its own
# server, found the production daemon through a machine-wide `pgrep -x buckle`, and killed it
# while its own pidfile stayed put (2026-09-25 21:54, 2026-09-26 02:32). Identity is the
# pidfile now, so the daemons that were alive before this file ran must still be alive.
test_production_daemon_untouched() {
  local pid
  for pid in $PRODUCTION_BUCKLE_PIDS; do
    assert_rc0 "isolation: live daemon $pid survives the whole suite" kill -0 "$pid"
  done
}
test_production_daemon_untouched
finish
