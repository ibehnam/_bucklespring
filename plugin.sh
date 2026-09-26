#!/usr/bin/env bash

# Bucklespring mechanical keyboard sound simulator plugin.

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

# Whether the status daemon computes the icon (tmuxd's `bucklespring` producer: the pidfile
# directory is a path watch and the holder's pid an exit watch, so the cell follows the fact).
# While it does, this script never writes the cell; it announces the intent options it changed.
daemon_owns_icon() {
  [ "$(tmux show -gqv @plugin_tmuxd_bucklespring 2>/dev/null)" = 1 ]
}

# Whether the last verified start failed the macOS keyboard event-tap permission — a TCC grant
# (Accessibility) held by the RESPONSIBLE process (the terminal, e.g. Ghostty), not by buckle
# itself; see docs/lessons.md. Single read site for @buckle_perm_error, mirroring is_running.
perm_error() {
  [ "$(tmux show -gqv @buckle_perm_error 2>/dev/null)" = "1" ]
}

# The selected profile: the last one started (@buckle_profile), else the
# built-in default. Single source for both the resume path and the menu mark.
current_profile() {
  local p
  p="$(tmux show -gqv @buckle_profile 2>/dev/null)" || true
  p="${p:-default}"
  buckle_profile_valid "$p" || p=default
  printf '%s' "$p"
}

# The selected gain (volume) percent; default 100 (full) when unset, then snapped onto the nearest
# TMUX_VOLUME_LEVELS member (tmux_volume_snap) so both consumers — do_start's `buckle -g` flag and
# the menu's bold mark — always get a canonical offered level: a persisted orphan (a value dropped
# from the level list) can't launch/bold at a level no menu row marks. snap(100)=100, so today's
# default stays behaviour-preserving. Mirrors current_profile's read-with-default structure. Baked
# into buckle's argv at launch (no hot-reload), so the snapped value is what a running buckle is
# relaunched with.
current_gain() {
  local g
  g="$(tmux show -gqv @buckle_gain 2>/dev/null)" || true
  tmux_volume_snap "${g:-100}"
}

# Buckle's OWN quiet window in minutes since midnight — independent of notif's by
# construction (nothing syncs the two; only the tmux_quiet_* rules are shared). Default
# 0/0 = from == to = OFF: dimming is opt-in here, so an existing install keeps sounding
# exactly as it did. Same read-with-default shape as current_profile / current_gain.
# Unlike the gain, this is NOT baked-and-frozen at launch: the window bounds go into
# buckle's argv and the fork re-evaluates them per keystroke, so a running buckle dims
# and un-dims on the clock with no timer and no boundary relaunch.
quiet_from() {
  local v; v="$(tmux show -gqv @buckle_quiet_from 2>/dev/null)" || true
  printf '%s' "${v:-0}"
}
quiet_to() {
  local v; v="$(tmux show -gqv @buckle_quiet_to 2>/dev/null)" || true
  printf '%s' "${v:-0}"
}

ensure_binary() {
  local bin="$BUCKLE_DIR/buckle"

  # Up to date when the binary exists and no source is newer than it. This makes
  # a committed source/submodule change actually reach the running process — the
  # Makefile is incremental, so the rebuild below is cheap and a no-op when
  # current. (A stale binary, not a missing one, was how a prior audio fix never
  # took effect.)
  if [[ -x "$bin" ]]; then
    local stale
    stale="$(find "$BUCKLE_DIR" -maxdepth 1 \( -name '*.c' -o -name '*.m' -o -name '*.h' -o -name 'Makefile' \) -newer "$bin" -print -quit 2>/dev/null)"
    [[ -z "$stale" ]] && return 0
  fi

  [ "${1:-}" = nobuild ] && { [[ -x "$bin" ]]; return; }

  # Re-enter this script with one argv so the popup's fish shell never owns
  # build control flow or status handling.
  tmux_popup -E -xC -yC -w 80% -h 60% \
    "'$SELF' build-popup '$BUCKLE_DIR'"
  [[ -x "$bin" ]]
}

_build() {                               # directory
  # One step on every platform: the Mac build links system frameworks only (the
  # native CoreAudio backend), so there is no dependency setup to run first.
  cd "$1" && make
}

build_popup() {                          # internal popup-body arm
  local dir=${1:?missing build directory} rc=0
  _build "$dir" || rc=$?
  printf '\npress any key to close\n'
  IFS= read -rsn1 _ || true
  exit "$rc"
}

do_start() {
  local profile="${1:-default}"
  buckle_profile_valid "$profile" || {
    printf 'bucklespring: unknown profile: %s\n' "$profile" >&2
    return 2
  }
  is_running && do_stop

  ensure_binary "${2:-}" || return 1

  # The quiet WINDOW is handed to the fork (which compares it against its own clock on
  # every keystroke); the quiet LEVEL is still derived here from TMUX_VOLUME_LEVELS, so
  # the level domain stays single-sourced in the shell and only the time comparison exists
  # in C. from == to (the default) makes the flags inert, so buckle behaves as before.
  local -a cmd=("./buckle" -g "$(current_gain)"
    --quiet-from "$(quiet_from)" --quiet-to "$(quiet_to)" --quiet-gain "$(tmux_volume_floor)")
  if [[ "$profile" != "default" ]]; then
    cmd+=(-p "./wav-klack/${profile}/")
  fi

  tmux set -g @buckle_profile "$profile"
  tmux set -g @buckle_enabled 1
  "$AI_DIR/tmux-status-persist.sh" save 2>/dev/null || true
  # Capture stderr to a log (device opens, device changes, the line naming the exit)
  # instead of discarding it, so audio routing and every death stay observable. Each start
  # truncates the log, so the previous life is kept once as buckle.log.1: that is where the
  # "terminated by SIG…" line of a daemon the status cell just saw die and restarted lives.
  mkdir -p "$BUCKLE_CACHE_DIR"
  [ ! -f "$BUCKLE_LOG" ] || mv -f "$BUCKLE_LOG" "$BUCKLE_LOG.1"
  # The shared detacher gives the daemon its own session and closes inherited
  # descriptors. Its lifetime therefore cannot depend on whether this action
  # came from tmux, a restore script, an SSH session, or a test runner.
  local pid
  pid=$(tmux_tmuxd_detach "$BUCKLE_DIR" "$BUCKLE_LOG" "${cmd[@]}") || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$pid" >"$BUCKLE_PIDFILE"
  refresh_icon 1   # optimistic green now — don't make the icon wait on the fork to settle
  # Async self-correct via tmux's native deferred background run — must NOT block a
  # sticky-menu reopen chained right after this call (tmux_menu_action's `; <reopen>`),
  # which only needs the tmux option already set above. verify-start (not a plain
  # icon-refresh) is what distinguishes a denied keyboard event-tap permission (orange,
  # self-service fixable) from any other silent launch failure (red).
  tmux_defer 1 "$SELF verify-start"
}

# Deferred (1s) re-check target for do_start's tmux_defer, called once the pidfile holder has
# had a beat to settle. This is the ONE place that surfaces the tap-permission failure —
# refresh_icon/icon-refresh stay surfacing-free for their other shared callers (stop/config-load/
# client-attached/resurrect). Loose "event tap" substring match (not the full message) survives
# any rewording of scan-mac.m's fprintf. Any other silent launch failure clears the flag too
# (generic red, same as never started) rather than leaving a stale orange from a previous start.
# refresh_icon runs BEFORE the tmux_msg guidance banner, not after: tmux_msg's refresh-client
# can fail (e.g. no attached client at that instant) and, under this file's set -e, would abort
# the function early — the icon update must not be hostage to that best-effort notification.
do_verify_start() {
  if is_running; then
    tmux set -gu @buckle_perm_error
  elif rg -q 'event tap' "$BUCKLE_LOG" 2>/dev/null; then
    tmux set -g @buckle_perm_error 1
  else
    tmux set -gu @buckle_perm_error
  fi
  refresh_icon
  if perm_error; then
    tmux_msg --class warning -d 4 "Bucklespring needs Accessibility permission; grant it in System Settings, Privacy & Security, restart, then use prefix-a b s"
  fi
}

do_teardown() {
  # Stop exactly the pidfile holder, and only while its command line still names buckle (a
  # recycled pid is someone else's). The old exact-name sweep was a footgun: it reached every
  # buckle on the machine, so a test tearing down its sandboxed copy killed the live daemon.
  tmux_daemon_stop "$BUCKLE_PIDFILE" "" buckle || true
  tmux set -gu @buckle_perm_error   # deliberate stop always renders red, never orange
  daemon_owns_icon || tmux set -gu @buckle_icon_color
}

do_stop() {
  # Intent first, then the process: the daemon's cell treats "pidfile gone while intent is on"
  # as a death and brings the process back, so a Stop must withdraw intent before it kills.
  tmux set -g @buckle_enabled 0
  "$AI_DIR/tmux-status-persist.sh" save 2>/dev/null || true
  do_teardown
}

do_toggle() {
  if is_running; then
    do_stop
    refresh_icon
  else
    do_start "$(current_profile)"
  fi
}

# Set the gain (volume) percent. Persist always; restart-to-apply only when running —
# gain is baked into buckle's argv at launch (no hot-reload), so a live buckle must be
# relaunched to pick it up. The trailing `|| true` is load-bearing under `set -euo
# pipefail`: when stopped, `is_running && …` returns 1 and would abort the (successful)
# common path (matches the repo's `is_running || true` discipline).
# Changing the volume must NOT start a stopped buckle — mirrors notif, where picking a
# level is not the same as unmuting.
do_gain() {
  tmux set -g @buckle_gain "$1"
  "$AI_DIR/tmux-status-persist.sh" save 2>/dev/null || true
  is_running && do_start "$(current_profile)" || true
}

# Commit the quiet-hours prompt (the row built by tmux_menu_quiet_row writes the typed text
# to @buckle_quiet_input and calls this). The shared helper owns read/parse/unset/write; the
# persist + restart-if-running follow-up is do_gain's rule applied to the other launch-time
# value, `|| true` included — under `set -euo pipefail` a stopped buckle's `is_running &&`
# would otherwise abort this successful path. Reopen through a detached tmux job; keeping
# this menu shell alive would make it the accidental parent of the audio daemon.
do_quiet_commit() {
  if tmux_quiet_commit @buckle_quiet_input @buckle_quiet_from @buckle_quiet_to; then
    "$AI_DIR/tmux-status-persist.sh" save 2>/dev/null || true
    is_running && do_start "$(current_profile)" || true
  else
    tmux_msg --class notice "$TMUX_QUIET_HINT"
  fi
  # The native menu router owns its validated callback and sticky reopen.  The
  # shell owns only parse, persistence, restart, and rejection feedback.
  [ "${1:-}" = --native ] && return 0
  tmux run-shell -b "TMUX_MENU_SELECT=${TMUX_MENU_SELECT:-} '$SELF' menu - ${1:-}" >/dev/null 2>&1 || true
}

# Reconcile persisted intent without interactive UI. This is shared by init and restore so config
# load, attach, plugin enable, and resurrect all converge through one idempotent path.
reconcile_intent() {
  local enabled running=0
  enabled="$(tmux show -gqv @buckle_enabled 2>/dev/null)"
  is_running && running=1
  if [ "$enabled" = "1" ]; then
    if [ "$running" = 0 ]; then
      do_start "$(current_profile)" nobuild || refresh_icon
    elif [ "${TMUX_PLUGIN_FORCE_CONVERGE:-}" = 1 ]; then
      do_teardown
      do_start "$(current_profile)" nobuild || refresh_icon
    else
      refresh_icon 1
    fi
  elif [ "$running" = 1 ]; then
    do_teardown
    refresh_icon 0
  else
    refresh_icon 0
  fi
}

# Seed preferences only when absent, then fully reconcile intent to process state.
do_init() {
  [ -n "$(tmux show -gqv @buckle_quiet_from 2>/dev/null)" ] || tmux set -g @buckle_quiet_from 0
  [ -n "$(tmux show -gqv @buckle_quiet_to 2>/dev/null)" ] || tmux set -g @buckle_quiet_to 0
  [ -n "$(tmux show -gqv @buckle_enabled 2>/dev/null)" ] || tmux set -g @buckle_enabled 0
  [ -n "$(tmux show -gqv @buckle_profile 2>/dev/null)" ] || tmux set -g @buckle_profile default
  [ -n "$(tmux show -gqv @buckle_gain 2>/dev/null)" ] || tmux set -g @buckle_gain 100
  daemon_owns_icon || tmux set -g @buckle_icon_color ''
  reconcile_intent
}

# Restore is a lifecycle alias for the same unattended reconciler.
do_restore() {
  reconcile_intent
}

# The cell's value for an observed or forced STATE (1 running, 0 not): green when running;
# otherwise orange while the last start failed the event-tap permission, red when merely
# stopped. ONE renderer for the bash writer below and for `plugin.sh icon`, which is the
# byte-for-byte oracle AI/tests/test-tmuxd-parity.sh holds the daemon's native cell to.
icon_value() { # [state]
  local state="${1:-}" off="$TMUX_RED"
  [ -n "$state" ] || { is_running && state=1 || state=0; }
  # Running but deaf: the system keeps disabling the tap (scan-mac.m says so once in the log),
  # so the daemon lives and no key reaches it. The permission colour, not green.
  if [ "$state" = "1" ] && tap_denied; then state=0; off="$TMUX_ORANGE"; fi
  [ "$state" = "0" ] && perm_error && off="$TMUX_ORANGE"
  tmux_render_state_icon "$TMUX_BUCKLE_ICON" "$state" "$TMUX_GREEN" "$off"
}

# The current life's tap is refused by the system when the denial line is the latest of the
# three markers in the log tail; a later recovery line or a later start supersedes it. The
# same three literals, in the same order rule, live in cells/bucklespring.rs.
tap_denied() {
  [ -f "$BUCKLE_LOG" ] || return 1
  tail -c 65536 "$BUCKLE_LOG" 2>/dev/null | awk '
    /buckle: event tap disabled by the system/ { d = NR }
    /buckle: event tap receiving events again/ { r = NR }
    /^buckle: started/ { s = NR }
    END { exit !(d && d > r && d > s) }'
}

show_icon() {
  icon_value
}

# Push state into @buckle_icon_color (event-driven status icon). Setting the
# option triggers an immediate status redraw — no #(shell) polling, no
# status-interval lag. Mirrors the ESC/Watch icon pattern.
#
# Optional arg forces the state: do_start passes 1 for an optimistic green that
# does NOT wait for the just-launched holder to settle (the pidfile lands a beat
# after the fork — that beat was the start lag). No arg = observe the pidfile
# (used by stop, init, and the client-attached/resurrect re-sync hooks).
#
# THE one 3-state writer (icon_value renders): running→green; not running & perm_error→orange
# (a denied event-tap permission, self-service fixable via the menu's Grant-permission row);
# else→red. Every shared caller (stop/config-load/client-attached/resurrect) goes through
# this one function. Once tmuxd's `bucklespring` producer owns the cell (its feature mirror
# on), the write is the daemon's and this becomes an announce; the bash writer stays for
# hosts that have not flipped, and is deleted with the last flip.
refresh_icon() {
  if daemon_owns_icon; then
    # The daemon renders the fact; tell it the intent options this script may have changed.
    # A forced optimistic state is meaningless here: the cell goes green when the pidfile's
    # holder is observed alive, not when a start was attempted.
    tmux_tmuxd_announce @buckle_enabled @buckle_perm_error
    return 0
  fi
  tmux set -g @buckle_icon_color "$(icon_value "${1:-}")"
}

# One-click fix affordance for the Grant-permission menu row (open_perms is local to this
# wrapper — no other consumer today; promote to tmux-ui-lib.sh only if a second feature needs
# a Privacy-pane opener).
open_perms() {
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
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
  # ABOVE the conditional perm_error row below so every sticky index baked in at build time
  # stays valid in the rebuilt menu (docs/ui/menus.md).
  rows+=("separator")
  tmux_menu_quiet_row rows "$(quiet_from)" "$(quiet_to)" h \
    @buckle_quiet_input "$SELF quiet-commit${back_b64:+ $back_b64}"

  # (existing) separator + Running toggle — serves as the volume|toggle divider. The ✓+bold
  # checkbox marks the daemon as running, matching every other stateful toggle.
  rows+=("separator")
  local running; is_running && running=on || running=off
  rows+=("toggle"$'\t'"$(tmux_menu_label on Running "$running")"$'\t's$'\t'"$SELF toggle")

  # One-click fix affordance: only while the last start failed the TCC-gated event tap.
  # One-shot (no reopen) — opening System Settings takes focus away from tmux anyway.
  if perm_error; then
    rows+=("separator")
    rows+=("direct"$'\t''⚠ Grant permission → open Settings'$'\t'p$'\t'"$(tmux_menu_action "$SELF open-perms")")
  fi

  tmux_menu_show BUCKLESPRING "$(tmux_menu_decode "$back_b64")" "${rows[@]}"
}

do_doctor() {
  local rc=0 stale=""
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
  if perm_error; then
    printf 'FAIL bucklespring: grant terminal Accessibility permission in System Settings\n'
    rc=1
  fi
  if [ -f "$BUCKLE_LOG" ]; then
    printf 'INFO bucklespring: log tail\n'
    tail -5 "$BUCKLE_LOG"
  fi
  return "$rc"
}

case "${1:-}" in
  init)         do_init ;;
  teardown)     do_teardown ;;
  purge)        : ;; # declared cache removal is core-owned
  doctor)       do_doctor ;;
  attach)       refresh_icon ;;
  menu)         if [ "${2:-}" = - ]; then show_menu "${3:-}"; else show_menu "${2:-}"; fi ;;
  start)        do_start "${2:-default}" ;;  # do_start owns the icon (optimistic + deferred self-correct)
  stop)         do_stop;                  refresh_icon ;;
  toggle)       do_toggle ;;                 # do_toggle owns the icon per branch
  gain)         do_gain "${2:?missing percent}" ;;  # do_start handles the icon when running; nothing to refresh when stopped
  quiet-commit) do_quiet_commit "${2:-}" ;;         # prompt round-trip target from the menu's quiet row
  menu-authority) menu_authority ;;
  profile-valid) buckle_profile_valid "${2:-}" ;;
  restore)      do_restore ;;
  icon)         show_icon ;;
  icon-refresh) refresh_icon ;;
  verify-start) do_verify_start ;;           # deferred self-correct target from do_start (was icon-refresh)
  open-perms)   open_perms ;;
  build-popup)  build_popup "${2:?missing build directory}" ;;
  *)            printf 'Usage: plugin.sh init|teardown|purge|doctor|attach|menu|start|stop|toggle|gain|quiet-commit|menu-authority|profile-valid|restore|icon|icon-refresh|verify-start|open-perms\n'; exit 1 ;;
esac
