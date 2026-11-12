#!/usr/bin/env bash

# Bucklespring mechanical keyboard sound simulator plugin.
#
# The daemon owns its identity, its log, and its settings: it claims its pidfile
# under an exclusive lock, rotates its own log, and rereads the settings file
# this script writes whenever it receives SIGHUP, so a gain, quiet-hours, or
# profile change never restarts it. This script launches it detached on every
# platform, and the reconciler that init, attach, and restore share restarts it.
# On macOS a process the tmux server starts borrows the keyboard grant of the
# terminal that started the server, its responsible process, so buckle needs no
# grant, signature, or supervisor of its own (docs/lessons.md). The status icon
# is the status daemon's `bucklespring` producer; this script never writes it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_CONFIG_DIR="${TMUX_CONFIG_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AI_DIR="$TMUX_CONFIG_DIR/AI"
SELF="$SCRIPT_DIR/plugin.sh"
# shellcheck source=tmux-ui-lib.sh
. "$AI_DIR/tmux-ui-lib.sh"
# shellcheck source=tmux-msg.sh
. "$AI_DIR/tmux-msg.sh"

BUCKLE_DIR="${BUCKLE_DIR:-$SCRIPT_DIR}"
BUCKLE_CACHE_DIR="${BUCKLE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/tmux-bucklespring}"
BUCKLE_LOG="${BUCKLE_LOG:-$BUCKLE_CACHE_DIR/buckle.log}"
BUCKLE_PIDFILE="${BUCKLE_PIDFILE:-$BUCKLE_CACHE_DIR/buckle.pid}"
BUCKLE_SETTINGS="${BUCKLE_SETTINGS:-$BUCKLE_CACHE_DIR/settings}"

# The profile enumeration is shared by the shell menu, action validator, and
# compiled native-menu authority.  A profile name is a directory component,
# never an arbitrary path supplied by a menu callback.
buckle_profile_rows() { # prints value<TAB>legacy menu label
  printf 'default\tIBM Model-M%s(default)\n' "$TMUX_MENU_FS"
  local dir name
  [[ -d "$BUCKLE_DIR/wav-klack" ]] || return 0
  while IFS= read -r dir; do
    name=${dir##*/}
    case "$name" in
      ''|*/*|*$'\t'*|*$'\n'*|*$'\r'*|*$'\036'*|*$'\037'*) continue ;;
    esac
    printf '%s\t%s\n' "$name" "$name"
  done < <(find "$BUCKLE_DIR/wav-klack" -mindepth 1 -maxdepth 1 -type d | sort)
}

buckle_profile_valid() { # profile
  local value label found=1
  while IFS=$'\t' read -r value label; do
    [ "$value" = "$1" ] && found=0
  done < <(buckle_profile_rows)
  return "$found"
}

buckle_absolute_path() { # path
  local path="$1"
  case "$path" in
    /*) printf '%s' "$path" ;;
    *) printf '%s/%s' "$PWD" "$path" ;;
  esac
}

# Compiler-only authority.  The compiler EXECUTES this owner; it never sources
# the plug-in or its UI/lifecycle libraries into its own process.
menu_authority() {
  local value label joined="" sep=""
  while IFS=$'\t' read -r value label; do
    joined+="$sep$value"$'\t'"$label"
    sep=$'\036'
  done < <(buckle_profile_rows)
  printf '@menu_buckle_profiles\t%s\n' "$joined"
  printf '@menu_buckle_pidfile\t%s\n' "$(buckle_absolute_path "$BUCKLE_PIDFILE")"
}

# The pidfile is the daemon's only handle; the holder must still be a buckle process. Never
# ask by process name: a name is machine-global, so a sandboxed suite in another cache root
# would see (and tear down) the production daemon (docs/lessons/daemons/identity.md).
is_running() {
  tmux_daemon_is_live "$BUCKLE_PIDFILE" buckle
}

# The five preferences, read with ONE tmux call into the PREF_* globals: each as
# stored, empty when unset. Every entry point that needs them reads them once,
# after its own writes, and the accessors below use what it read. A read that
# returns no rows at all fails, so a server that did not answer is never taken
# for "off", which would stop a running daemon, or for the defaults, which would
# overwrite the settings file.
read_prefs() {
  local name value rows=0
  PREF_ENABLED="" PREF_PROFILE="" PREF_GAIN="" PREF_QUIET_FROM="" PREF_QUIET_TO=""
  while IFS=$'\t' read -r name value; do
    rows=$((rows + 1))
    case "$name" in
      @buckle_enabled) PREF_ENABLED=$value ;;
      @buckle_profile) PREF_PROFILE=$value ;;
      @buckle_gain) PREF_GAIN=$value ;;
      @buckle_quiet_from) PREF_QUIET_FROM=$value ;;
      @buckle_quiet_to) PREF_QUIET_TO=$value ;;
    esac
  done < <(tmux_global_option_dump @buckle_enabled @buckle_profile @buckle_gain \
    @buckle_quiet_from @buckle_quiet_to)
  [ "$rows" -gt 0 ]
}

# The selected profile: the last one started (@buckle_profile), else the
# built-in default. Single source for the settings file and the menu mark.
current_profile() {
  local p="${PREF_PROFILE:-default}"
  buckle_profile_valid "$p" || p=default
  printf '%s' "$p"
}

# The selected gain (volume) percent; default 100 (full) when unset, then snapped onto the
# nearest TMUX_VOLUME_LEVELS member (tmux_volume_snap) so both consumers, the settings file
# and the menu's bold mark, always get a canonical offered level: a persisted orphan (a value
# dropped from the level list) can't play or bold at a level no menu row marks.
current_gain() {
  tmux_volume_snap "${PREF_GAIN:-100}"
}

# Buckle's OWN quiet window in minutes since midnight, independent of notif's by
# construction (nothing syncs the two; only the tmux_quiet_* rules are shared). Default
# 0/0 = from == to = OFF: dimming is opt-in here, so an existing install keeps sounding
# exactly as it did. The daemon compares the window against its own clock on every
# keystroke, so it dims and un-dims with no timer and no relaunch.
quiet_from() {
  printf '%s' "${PREF_QUIET_FROM:-0}"
}
quiet_to() {
  printf '%s' "${PREF_QUIET_TO:-0}"
}

# ---------------------------------------------------------------------------
# Settings: the one channel from the preferences to a running daemon.

# Project the durable preferences, as the caller's read_prefs left them, into the
# daemon's settings file, compare-first: rc 0 when the file changed, 1 when it already
# said this. The quiet LEVEL is derived here from TMUX_VOLUME_LEVELS, so the level
# domain stays single-sourced in the shell and only the time comparison exists in C.
write_settings() {
  local want have=""
  want=$(printf 'gain=%s\nquiet_from=%s\nquiet_to=%s\nquiet_gain=%s\nprofile=%s\n' \
    "$(current_gain)" "$(quiet_from)" "$(quiet_to)" "$(tmux_volume_floor)" "$(current_profile)")
  [ ! -f "$BUCKLE_SETTINGS" ] || have=$(cat "$BUCKLE_SETTINGS" 2>/dev/null) || true
  [ "$have" = "$want" ] && return 1
  mkdir -p "$BUCKLE_CACHE_DIR"
  printf '%s\n' "$want" | tmux_atomic_write "$BUCKLE_SETTINGS"
}

# Tell the pidfile's holder to reread its settings. Only a validated holder is
# signalled: a recycled pid is someone else's.
signal_holder() {
  local pid
  is_running || return 0
  read -r pid 2>/dev/null < "$BUCKLE_PIDFILE" || return 0
  kill -HUP "$pid" 2>/dev/null || true
}

# Settings changed by a menu: rewrite, and let a live daemon apply them at its next click.
apply_settings() {
  read_prefs || return 0
  if write_settings; then signal_holder; fi
}

# ---------------------------------------------------------------------------
# Launch and stop.

# Wait up to a second for the daemon's own claim: the pidfile names a live buckle.
wait_live() {
  local tries=20
  while [ "$tries" -gt 0 ]; do
    is_running && return 0
    tmux_nap 0.05
    tries=$((tries - 1))
  done
  return 1
}

# Start the daemon detached: its own session, no inherited descriptors, and a
# lifetime independent of the caller. The caller has written the settings; a
# binary older than its sources is never launched (ensure_binary says why). The
# daemon rotates and opens its own log as its first argument; the detacher's
# output would truncate the previous life's log before it could. Mute keycode 0
# turns the double-tap mute off: the daemon drops code 0 before the mute check,
# and a mute behind Scroll Lock silenced it with the icon still green.
launch() {
  binary_current || return 1
  mkdir -p "$BUCKLE_CACHE_DIR"
  tmux_tmuxd_detach "$BUCKLE_DIR" /dev/null ./buckle \
    --log "$BUCKLE_LOG" --pidfile "$BUCKLE_PIDFILE" --settings "$BUCKLE_SETTINGS" \
    --mute-keycode 0 >/dev/null || return 1
  wait_live || printf 'bucklespring: no live holder a second after launch; see %s\n' "$BUCKLE_LOG" >&2
  return 0
}

# Stop the pidfile's holder. One that outlives SIGTERM is reported on stderr, the
# plugin log, and fails, rather than passing for stopped.
stop_daemon() {
  tmux_daemon_stop "$BUCKLE_PIDFILE" "" buckle && return 0
  printf 'bucklespring: the daemon in %s survived SIGTERM\n' "$BUCKLE_PIDFILE" >&2
  return 1
}

# A live holder to replace: the binary is newer than its claim (new code), or the
# claim is older than this server. A detached daemon outlives the server that
# started it, and its keyboard grant stays attributed to that server's terminal,
# which a terminal restart leaves dead; a relaunch inherits this server's. The
# claim is the pidfile's mtime, the generation rule every pane-id cache obeys.
holder_outdated() {
  [ "$BUCKLE_DIR/buckle" -nt "$BUCKLE_PIDFILE" ] && return 0
  local start
  start=$(tmux display -p '#{start_time}' 2>/dev/null) || return 1
  [ -n "$start" ] && [ "$(tmux_get_mtime "$BUCKLE_PIDFILE")" -lt "$start" ] 2>/dev/null
}

relaunch() {
  # A holder that survives SIGTERM still loses its pidfile, and its identity watch ends it
  # once the new daemon's claim names another file, so the launch goes ahead.
  stop_daemon || true
  launch || true
}

# ---------------------------------------------------------------------------
# Building.

# The first of the daemon's sources newer than its binary, if any: the one test
# binary_current and the doctor share.
stale_source() {
  local src
  for src in "$BUCKLE_DIR"/*.c "$BUCKLE_DIR"/*.m "$BUCKLE_DIR"/*.h "$BUCKLE_DIR/Makefile"; do
    [ "$src" -nt "$BUCKLE_DIR/buckle" ] && { printf '%s' "$src"; return 0; }
  done
  return 1
}

# Current when the binary exists and no source is newer than it. This makes a
# committed source/submodule change actually reach the running process — the
# Makefile is incremental, so a rebuild is cheap and a no-op when current. (A
# stale binary, not a missing one, was how a prior audio fix never took effect.)
binary_current() {
  [ -x "$BUCKLE_DIR/buckle" ] && ! stale_source >/dev/null
}

# Only a current binary is launched, because the daemon's argv contract moves
# with its sources. An interactive caller builds in a popup; an unattended one
# (init, attach, restore) never opens one and builds quietly into the build log.
ensure_binary() { # [quiet]
  binary_current && return 0
  if [ "${1:-}" = quiet ]; then
    mkdir -p "$BUCKLE_CACHE_DIR"
    _build "$BUCKLE_DIR" >>"$BUCKLE_CACHE_DIR/build.log" 2>&1 || true
  else
    # Re-enter this script with one argv so the popup's fish shell never owns
    # build control flow or status handling.
    tmux_popup -E -xC -yC -w 80% -h 60% \
      "'$SELF' build-popup '$BUCKLE_DIR'"
  fi
  binary_current && return 0
  printf 'bucklespring: %s/buckle is missing or older than its sources; not launching it\n' "$BUCKLE_DIR" >&2
  return 1
}

_build() {                               # directory
  # The Mac build links system frameworks only (the native CoreAudio backend),
  # so there is no dependency setup to run first.
  (cd "$1" && make)
}

build_popup() {                          # internal popup-body arm
  local dir=${1:?missing build directory} rc=0
  _build "$dir" || rc=$?
  printf '\npress any key to close\n'
  IFS= read -rsn1 _ || true
  exit "$rc"
}

# ---------------------------------------------------------------------------
# Lifecycle.

# The daemon's cell renders the fact; tell the status daemon which intent this
# script may have changed.
refresh_icon() {
  tmux_tmuxd_announce @buckle_enabled
}

do_start() {
  local profile="${1:-default}"
  buckle_profile_valid "$profile" || {
    printf 'bucklespring: unknown profile: %s\n' "$profile" >&2
    return 2
  }
  ensure_binary "${2:-}" || return 1
  tmux set -g @buckle_profile "$profile"
  tmux set -g @buckle_enabled 1
  "$AI_DIR/tmux-status-persist.sh" save 2>/dev/null || true
  if read_prefs; then write_settings || true; fi
  # A live daemon takes the new profile at its next click; an outdated one restarts.
  if is_running; then
    if holder_outdated; then relaunch; else signal_holder; fi
  else
    launch || true
  fi
  refresh_icon
}

do_teardown() {
  # Stop exactly the pidfile holder, and only while its command line still names buckle (a
  # recycled pid is someone else's). The old exact-name sweep was a footgun: it reached every
  # buckle on the machine, so a test tearing down its sandboxed copy killed the live daemon.
  stop_daemon
}

do_stop() {
  local rc=0
  tmux set -g @buckle_enabled 0
  "$AI_DIR/tmux-status-persist.sh" save 2>/dev/null || true
  stop_daemon || rc=1
  refresh_icon
  return "$rc"
}

do_toggle() {
  if is_running; then
    do_stop
  else
    read_prefs || return 0
    do_start "$(current_profile)"
  fi
}

# Set the gain (volume) percent. Changing the volume must NOT start a stopped buckle,
# mirroring notif, where picking a level is not the same as unmuting.
do_gain() {
  tmux set -g @buckle_gain "$1"
  "$AI_DIR/tmux-status-persist.sh" save 2>/dev/null || true
  apply_settings
}

# Commit the quiet-hours prompt. The shared helper owns the parse and the paired write. The
# menu's row (tmux_menu_quiet_row) and the native router pass the typed text as --value; an
# older row left it in @buckle_quiet_input, which the helper reads and unsets. Reopen
# through a detached tmux job; keeping this menu shell alive would make it the accidental
# parent of anything it started.
do_quiet_commit() { # [--native] [--ui] [BACK] [--value TEXT]
  local native=0 back="" value_set=0 value="" committed=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --native) native=1 ;;
      --ui) ;;
      --value) shift; [ "$#" -gt 0 ] || return 2; value="$1"; value_set=1 ;;
      *) back="$1" ;;
    esac
    shift
  done
  if [ "$value_set" = 1 ]; then
    tmux_quiet_commit @buckle_quiet_input @buckle_quiet_from @buckle_quiet_to "$value" && committed=0
  else
    tmux_quiet_commit @buckle_quiet_input @buckle_quiet_from @buckle_quiet_to && committed=0
  fi
  if [ "$committed" = 0 ]; then
    "$AI_DIR/tmux-status-persist.sh" save 2>/dev/null || true
    apply_settings
  else
    tmux_msg --class notice "$TMUX_QUIET_HINT"
  fi
  # The native menu router owns its validated callback and sticky reopen.  The
  # shell owns only parse, persistence, and rejection feedback.
  [ "$native" = 1 ] && return 0
  tmux run-shell -b "TMUX_MENU_SELECT=${TMUX_MENU_SELECT:-} '$SELF' menu - $back" >/dev/null 2>&1 || true
}

# Reconcile persisted intent without interactive UI. Init, attach, and restore share it,
# and a native menu choice reaches it through core's `converge`, which runs this attach
# hook, so it is idempotent and restarts a live daemon only for new code: a settings
# change is a SIGHUP.
reconcile_intent() {
  local changed=0
  # One read of the preferences, and one that returns nothing changes nothing.
  read_prefs || return 0
  write_settings && changed=1
  if [ "$PREF_ENABLED" = 1 ]; then
    # New sources are built before anything is decided, so a daemon they outdate
    # is relaunched below, as is one another server started; a build that fails
    # leaves a live daemon alone.
    ensure_binary quiet || true
    if ! is_running; then
      launch || true
    elif holder_outdated && binary_current; then
      relaunch
    elif [ "$changed" = 1 ]; then
      signal_holder
    fi
  elif is_running; then
    # Off, yet a daemon runs: it outlived the server that started it, or a
    # restore brought back a server whose intent says off.
    stop_daemon || true
  fi
  refresh_icon
}

# Seed preferences only when absent, then fully reconcile intent to process state.
do_init() {
  [ -n "$(tmux show -gqv @buckle_quiet_from 2>/dev/null)" ] || tmux set -g @buckle_quiet_from 0
  [ -n "$(tmux show -gqv @buckle_quiet_to 2>/dev/null)" ] || tmux set -g @buckle_quiet_to 0
  "$AI_DIR/tmux-plugin-lib.sh" seed-flags bucklespring @buckle_enabled >/dev/null 2>&1 || true
  [ -n "$(tmux show -gqv @buckle_profile 2>/dev/null)" ] || tmux set -g @buckle_profile default
  [ -n "$(tmux show -gqv @buckle_gain 2>/dev/null)" ] || tmux set -g @buckle_gain 100
  # TRANSITIONAL (delete once no live server predates the producer): the retired
  # permission flag, which nothing reads any more.
  tmux set -gu @buckle_perm_error 2>/dev/null || true
  reconcile_intent
}

# The daemon's cell is the one judge of a refused keyboard tap; the menu and the
# doctor read its published verdict instead of parsing the log a second time.
denied_published() {
  local published
  published="$(tmux show -gqv @buckle_icon_color 2>/dev/null)" || return 1
  [ -n "$published" ] && [ "$published" = "${TMUX_ORANGE}${TMUX_BUCKLE_ICON}${TMUX_RESET}" ]
}

# One-click fix affordance for the permission menu row: the grant belongs to the
# terminal that started the tmux server, in Input Monitoring.
open_perms() {
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
}

show_menu() {
  local back_b64="${1:-}"
  read_prefs || true
  local current; current="$(current_profile)"
  # Sticky reopen is declared once as constructor metadata. Toggle rows stay pure; compose
  # derives each row's index and owns the action + reopen chain.
  local reopen="$SELF menu -${back_b64:+ $back_b64}"
  local -a rows=("self"$'\t'"$reopen")

  # Profile picker and action validator consume this same enumeration.
  local -a items=()
  local value label
  while IFS=$'\t' read -r value label; do
    items+=( "$value"$'\t'"$label" )
  done < <(buckle_profile_rows)
  tmux_menu_radio_rows rows "$current" "$SELF start" 0 "${items[@]}"

  # Divider between the sound-picker section and the volume section, then the volume group
  # (keys continue after the profiles: next free key = item count). Bold the EFFECTIVE
  # level (quiet window applied), not the raw @buckle_gain, so the mark matches what buckle
  # actually plays right now — symmetric with notif.
  rows+=("separator")
  tmux_menu_volume_rows rows \
    "$(tmux_volume_effective "$(current_gain)" "$(quiet_from)" "$(quiet_to)")" \
    "$SELF gain" "${#items[@]}"

  # Separator + the quiet window that caps those levels — same shared row as notif's, and
  # ABOVE the conditional permission row below so every sticky index baked in at build time
  # stays valid in the rebuilt menu (docs/ui/menus.md).
  rows+=("separator")
  tmux_menu_quiet_row rows "$(quiet_from)" "$(quiet_to)" h \
    "$SELF quiet-commit${back_b64:+ $back_b64}"

  # (existing) separator + Running toggle — serves as the volume|toggle divider. The ✓+bold
  # checkbox marks the daemon as running, matching every other stateful toggle.
  rows+=("separator")
  local running; is_running && running=on || running=off
  rows+=("toggle"$'\t'"$(tmux_menu_label on Running "$running")"$'\t's$'\t'"$SELF toggle")

  # One-click fix affordance: only while the cell shows a refused keyboard tap.
  # One-shot (no reopen) — opening System Settings takes focus away from tmux anyway.
  if denied_published; then
    rows+=("separator")
    rows+=("direct"$'\t''⚠ Input Monitoring → open Settings'$'\t'p$'\t'"$(tmux_menu_action "$SELF open-perms")")
  fi

  tmux_menu_show BUCKLESPRING "$(tmux_menu_decode "$back_b64")" "${rows[@]}"
}

do_doctor() {
  # One record per check through the shared emitters (AI/tmux-plugin-lib.sh);
  # the collector reads them and the status daemon's registry keeps them. The
  # exit status means "finished", never "healthy". A log's last lines come from
  # core's own tail reader, which is quiet for a missing or empty file.
  local stale plugin_log _TMUX_DOCTOR_TAIL=""
  # shellcheck source=tmux-plugin-lib.sh
  . "$AI_DIR/tmux-plugin-lib.sh"
  if [ ! -x "$BUCKLE_DIR/buckle" ]; then
    tmux_doctor_warn bucklespring.binary "binary missing" \
      --remedy "Build it with make in modules/bucklespring (system frameworks only on macOS); until then no key sounds play." \
      --fix make -C modules/bucklespring
  elif stale=$(stale_source); then
    tmux_doctor_info bucklespring.binary "binary is older than its source" --detail "$stale" \
      --remedy "Rebuild it with make in modules/bucklespring; the fix does that now." --fix make -C modules/bucklespring
  else
    tmux_doctor_ok bucklespring.binary "binary is current"
  fi
  read_prefs || true
  if is_running; then
    tmux_doctor_ok bucklespring.daemon "pidfile holder is live"
  elif [ "$PREF_ENABLED" = 1 ]; then
    # A failed start says why only on stderr, which core keeps as the plugin log, and a
    # red icon also means "off by choice", so intent on with no holder is a warning.
    plugin_log=$(tmux_plugin_expand_path "%CACHE%/tmux/plugin-bucklespring.log")
    _tmux_doctor_tail "$plugin_log" 5
    tmux_doctor_warn bucklespring.daemon "key sounds are on, but no daemon runs" \
      --detail "$plugin_log: ${_TMUX_DOCTOR_TAIL:-(empty)}" \
      --remedy "Reconcile the plugin, which builds and starts the daemon; the fix does that now. The plugin log's last lines, in the detail, say why the last start failed." \
      --fix AI/tmux-plugin-lib.sh apply bucklespring
  elif [ -f "$BUCKLE_PIDFILE" ]; then
    tmux_doctor_info bucklespring.daemon "stale pidfile" --detail "$BUCKLE_PIDFILE"
  fi
  # The daemon keeps the keyboard and the speakers for a pidfile under the account's home;
  # elsewhere, a test sandbox's rule, it holds its claim inert, green yet silent.
  if is_running && rg -q -F 'holding the claim without the keyboard or the speakers' "$BUCKLE_LOG" 2>/dev/null; then
    tmux_doctor_fault bucklespring.inert "the daemon holds its claim without the keyboard or the speakers" \
      --detail "$BUCKLE_PIDFILE is outside the account's home" \
      --remedy "Keep the pidfile under the account's home: remove the XDG_CACHE_HOME or BUCKLE_PIDFILE that points elsewhere, then Stop and Start the daemon from the plugin's menu."
  fi
  if denied_published; then
    tmux_doctor_fault bucklespring.input_monitoring "the keyboard tap is refused" \
      --remedy "Grant Input Monitoring to the terminal that started tmux (the plugin menu's row opens that pane), or restart that terminal if it was updated while running." \
      --fix modules/bucklespring/plugin.sh open-perms
  fi
  if [ -f "$BUCKLE_LOG" ]; then
    _tmux_doctor_tail "$BUCKLE_LOG" 5
    tmux_doctor_info bucklespring.log "log tail" --detail "$_TMUX_DOCTOR_TAIL"
  fi
  return 0
}

case "${1:-}" in
  init)          do_init ;;
  teardown)      do_teardown ;;
  purge)         : ;;                 # core's teardown stops the daemon; cache removal is core-owned
  doctor)        do_doctor ;;
  attach)        reconcile_intent ;;  # attach restarts a dead daemon
  menu)          if [ "${2:-}" = - ]; then show_menu "${3:-}"; else show_menu "${2:-}"; fi ;;
  start)         do_start "${2:-default}" ;;
  stop)          do_stop ;;
  toggle)        do_toggle ;;
  gain)          do_gain "${2:?missing percent}" ;;
  quiet-commit)  shift; do_quiet_commit "$@" ;;      # prompt round-trip target from the menu's quiet row
  menu-authority) menu_authority ;;
  profile-valid) buckle_profile_valid "${2:-}" ;;
  restore)       reconcile_intent ;;
  icon-refresh)  refresh_icon ;;
  open-perms)    open_perms ;;
  build-popup)   build_popup "${2:?missing build directory}" ;;
  *)             printf 'Usage: plugin.sh init|teardown|purge|doctor|attach|menu|start|stop|toggle|gain|quiet-commit|menu-authority|profile-valid|restore|icon-refresh|open-perms\n'; exit 1 ;;
esac
