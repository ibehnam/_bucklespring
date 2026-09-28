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

# The selected profile: the last one started (@buckle_profile), else the
# built-in default. Single source for the settings file and the menu mark.
current_profile() {
  local p
  p="$(tmux show -gqv @buckle_profile 2>/dev/null)" || true
  p="${p:-default}"
  buckle_profile_valid "$p" || p=default
  printf '%s' "$p"
}

# The selected gain (volume) percent; default 100 (full) when unset, then snapped onto the
# nearest TMUX_VOLUME_LEVELS member (tmux_volume_snap) so both consumers, the settings file
# and the menu's bold mark, always get a canonical offered level: a persisted orphan (a value
# dropped from the level list) can't play or bold at a level no menu row marks.
current_gain() {
  local g
  g="$(tmux show -gqv @buckle_gain 2>/dev/null)" || true
  tmux_volume_snap "${g:-100}"
}

# Buckle's OWN quiet window in minutes since midnight, independent of notif's by
# construction (nothing syncs the two; only the tmux_quiet_* rules are shared). Default
# 0/0 = from == to = OFF: dimming is opt-in here, so an existing install keeps sounding
# exactly as it did. The daemon compares the window against its own clock on every
# keystroke, so it dims and un-dims with no timer and no relaunch.
quiet_from() {
  local v; v="$(tmux show -gqv @buckle_quiet_from 2>/dev/null)" || true
  printf '%s' "${v:-0}"
}
quiet_to() {
  local v; v="$(tmux show -gqv @buckle_quiet_to 2>/dev/null)" || true
  printf '%s' "${v:-0}"
}

# ---------------------------------------------------------------------------
# Settings: the one channel from the preferences to a running daemon.

# Project the durable preferences into the daemon's settings file, compare-first:
# rc 0 when the file changed, 1 when it already said this. The quiet LEVEL is derived
# here from TMUX_VOLUME_LEVELS, so the level domain stays single-sourced in the shell
# and only the time comparison exists in C.
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
# output would truncate the previous life's log before it could.
launch() {
  binary_current || return 1
  mkdir -p "$BUCKLE_CACHE_DIR"
  tmux_tmuxd_detach "$BUCKLE_DIR" /dev/null ./buckle \
    --log "$BUCKLE_LOG" --pidfile "$BUCKLE_PIDFILE" --settings "$BUCKLE_SETTINGS" >/dev/null || return 1
  wait_live || printf 'bucklespring: no live holder a second after launch; see %s\n' "$BUCKLE_LOG" >&2
  return 0
}

stop_daemon() {
  tmux_daemon_stop "$BUCKLE_PIDFILE" "" buckle || true
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
  stop_daemon
  launch || true
}

# ---------------------------------------------------------------------------
# Building.

# Current when the binary exists and no source is newer than it. This makes a
# committed source/submodule change actually reach the running process — the
# Makefile is incremental, so a rebuild is cheap and a no-op when current. (A
# stale binary, not a missing one, was how a prior audio fix never took effect.)
binary_current() {
  local bin="$BUCKLE_DIR/buckle" stale
  [[ -x "$bin" ]] || return 1
  stale="$(find "$BUCKLE_DIR" -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' -o -name 'Makefile' \) -newer "$bin" -print -quit 2>/dev/null)"
  [[ -z "$stale" ]]
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
  write_settings || true
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
  tmux set -g @buckle_enabled 0
  "$AI_DIR/tmux-status-persist.sh" save 2>/dev/null || true
  stop_daemon
  refresh_icon
}

do_toggle() {
  if is_running; then
    do_stop
  else
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

# Commit the quiet-hours prompt (the row built by tmux_menu_quiet_row writes the typed text
# to @buckle_quiet_input and calls this). The shared helper owns read/parse/unset/write.
# Reopen through a detached tmux job; keeping this menu shell alive would make it the
# accidental parent of anything it started.
do_quiet_commit() {
  if tmux_quiet_commit @buckle_quiet_input @buckle_quiet_from @buckle_quiet_to; then
    "$AI_DIR/tmux-status-persist.sh" save 2>/dev/null || true
    apply_settings
  else
    tmux_msg --class notice "$TMUX_QUIET_HINT"
  fi
  # The native menu router owns its validated callback and sticky reopen.  The
  # shell owns only parse, persistence, and rejection feedback.
  [ "${1:-}" = --native ] && return 0
  tmux run-shell -b "TMUX_MENU_SELECT=${TMUX_MENU_SELECT:-} '$SELF' menu - ${1:-}" >/dev/null 2>&1 || true
}

# Reconcile persisted intent without interactive UI. Init, attach, and restore share it,
# and the native menu reaches it through core's forced apply, so it is idempotent and
# restarts a live daemon only for new code: a settings change is a SIGHUP.
reconcile_intent() {
  local enabled changed=0
  enabled="$(tmux show -gqv @buckle_enabled 2>/dev/null)"
  write_settings && changed=1
  if [ "$enabled" = 1 ]; then
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
    stop_daemon
  fi
  refresh_icon
}

# Seed preferences only when absent, then fully reconcile intent to process state.
do_init() {
  [ -n "$(tmux show -gqv @buckle_quiet_from 2>/dev/null)" ] || tmux set -g @buckle_quiet_from 0
  [ -n "$(tmux show -gqv @buckle_quiet_to 2>/dev/null)" ] || tmux set -g @buckle_quiet_to 0
  [ -n "$(tmux show -gqv @buckle_enabled 2>/dev/null)" ] || tmux set -g @buckle_enabled 0
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
    @buckle_quiet_input "$SELF quiet-commit${back_b64:+ $back_b64}"

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
  local rc=0 stale="" age
  if [ -x "$BUCKLE_DIR/buckle" ]; then
    stale=$(find "$BUCKLE_DIR" -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' -o -name Makefile \) -newer "$BUCKLE_DIR/buckle" -print -quit 2>/dev/null)
    [ -z "$stale" ] && printf 'INFO bucklespring: binary is current\n' \
      || printf 'INFO bucklespring: binary is stale (%s)\n' "$stale"
  else
    printf 'FAIL bucklespring: binary missing; run make in modules/bucklespring\n'
    rc=1
  fi
  if tmux_daemon_is_live "$BUCKLE_PIDFILE" buckle; then
    printf 'INFO bucklespring: pidfile holder is live\n'
  elif [ -f "$BUCKLE_PIDFILE" ]; then
    printf 'INFO bucklespring: stale pidfile %s\n' "$BUCKLE_PIDFILE"
  fi
  if [ -f "$BUCKLE_CACHE_DIR/render.hb" ]; then
    age=$(( $(date +%s) - $(tmux_get_mtime "$BUCKLE_CACHE_DIR/render.hb") ))
    printf 'INFO bucklespring: audio heartbeat %ss old\n' "$age"
  fi
  if denied_published; then
    printf 'FAIL bucklespring: the keyboard tap is refused; grant Input Monitoring to the terminal that started tmux (the menu opens the pane), or restart that terminal if it was updated while running\n'
    rc=1
  fi
  if [ -f "$BUCKLE_LOG" ]; then
    printf 'INFO bucklespring: log tail\n'
    tail -5 "$BUCKLE_LOG"
  fi
  return "$rc"
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
  quiet-commit)  do_quiet_commit "${2:-}" ;;         # prompt round-trip target from the menu's quiet row
  menu-authority) menu_authority ;;
  profile-valid) buckle_profile_valid "${2:-}" ;;
  restore)       reconcile_intent ;;
  icon-refresh)  refresh_icon ;;
  open-perms)    open_perms ;;
  build-popup)   build_popup "${2:?missing build directory}" ;;
  *)             printf 'Usage: plugin.sh init|teardown|purge|doctor|attach|menu|start|stop|toggle|gain|quiet-commit|menu-authority|profile-valid|restore|icon-refresh|open-perms\n'; exit 1 ;;
esac
