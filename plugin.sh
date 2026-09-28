#!/usr/bin/env bash

# Bucklespring mechanical keyboard sound simulator plugin.
#
# The daemon owns its identity, its log, and its settings: it claims its pidfile
# under an exclusive lock, rotates its own log, and rereads the settings file
# this script writes whenever it receives SIGHUP, so a gain, quiet-hours, or
# profile change never restarts it. On macOS it is a LaunchAgent, which launchd
# restarts after a crash and starts at login while intent is on; on Linux this
# script launches it detached, and the reconciler that init, attach, and restore
# share restarts it. The status icon is the status daemon's `bucklespring`
# producer; this script never writes it.

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
# The platform decides the supervisor; the suite forces either branch.
BUCKLE_OS="${BUCKLE_OS:-$(uname -s)}"
# The LaunchAgent. The manifest's `durable` row names the same plist, so purge
# removes exactly the file this script renders.
BUCKLE_LABEL=com.behnam.bucklespring
BUCKLE_AGENTS_DIR="${BUCKLE_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
BUCKLE_PLIST="$BUCKLE_AGENTS_DIR/$BUCKLE_LABEL.plist"
BUCKLE_TEMPLATE="$SCRIPT_DIR/launchd/$BUCKLE_LABEL.plist.in"
BUCKLE_LAUNCHCTL="${BUCKLE_LAUNCHCTL:-launchctl}"
# The host's local code-signing identity (`sign-identity` creates it once).
BUCKLE_SIGN_NAME="${BUCKLE_SIGN_NAME:-Bucklespring Local Signing}"

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
# Supervision. macOS: launchd, through one function the suite fakes. Only the
# checkout the running server loaded manages the LaunchAgent, because it is
# machine-global: a suite's isolated server or a second checkout must never
# bootstrap, replace, or unload the live one.

darwin() { [ "$BUCKLE_OS" = Darwin ]; }

owns_launchd() {
  darwin && tmux_server_runs_checkout "$TMUX_CONFIG_DIR"
}

_launchd() { # print|bootstrap|bootout|kickstart|enable|disable
  local domain="gui/$UID"
  case "$1" in
    print)     "$BUCKLE_LAUNCHCTL" print "$domain/$BUCKLE_LABEL" ;;
    bootstrap) "$BUCKLE_LAUNCHCTL" bootstrap "$domain" "$BUCKLE_PLIST" ;;
    bootout)   "$BUCKLE_LAUNCHCTL" bootout "$domain/$BUCKLE_LABEL" ;;
    kickstart) "$BUCKLE_LAUNCHCTL" kickstart -k "$domain/$BUCKLE_LABEL" ;;
    enable)    "$BUCKLE_LAUNCHCTL" enable "$domain/$BUCKLE_LABEL" ;;
    disable)   "$BUCKLE_LAUNCHCTL" disable "$domain/$BUCKLE_LABEL" ;;
    *) return 2 ;;
  esac
}

agent_loaded() { _launchd print >/dev/null 2>&1; }

xml_escape() { # text
  local s="$1"
  s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}
  printf '%s' "$s"
}

# The plist this checkout wants, from the template: every path is absolute, and
# the settings file carries everything that changes, so the plist changes only
# when a path does.
render_plist() {
  local t
  t=$(cat "$BUCKLE_TEMPLATE") || return 1
  # Bash 5.2 expands `&` in a substitution's replacement; the escapes carry one.
  shopt -u patsub_replacement 2>/dev/null || true
  t=${t//@LABEL@/$BUCKLE_LABEL}
  t=${t//@BUCKLE@/$(xml_escape "$(buckle_absolute_path "$BUCKLE_DIR")/buckle")}
  t=${t//@DIR@/$(xml_escape "$(buckle_absolute_path "$BUCKLE_DIR")")}
  t=${t//@LOG@/$(xml_escape "$(buckle_absolute_path "$BUCKLE_LOG")")}
  t=${t//@PIDFILE@/$(xml_escape "$(buckle_absolute_path "$BUCKLE_PIDFILE")")}
  t=${t//@SETTINGS@/$(xml_escape "$(buckle_absolute_path "$BUCKLE_SETTINGS")")}
  printf '%s\n' "$t"
}

# Install the plist, compare-first: rc 0 when it changed, 1 when it was current.
install_plist() {
  local want have=""
  want=$(render_plist) || return 2
  [ ! -f "$BUCKLE_PLIST" ] || have=$(cat "$BUCKLE_PLIST" 2>/dev/null) || true
  [ "$have" = "$want" ] && return 1
  mkdir -p "$BUCKLE_AGENTS_DIR"
  printf '%s\n' "$want" | tmux_atomic_write "$BUCKLE_PLIST"
}

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

# Start the daemon under its platform's supervisor. The caller has written the settings;
# a binary older than its sources is never handed to a supervisor (ensure_binary says why).
launch() {
  binary_current || return 1
  mkdir -p "$BUCKLE_CACHE_DIR"
  if darwin; then
    owns_launchd || { printf 'bucklespring: launchd belongs to the server that loaded %s\n' "$TMUX_CONFIG_DIR" >&2; return 1; }
    # A holder launchd does not know is a legacy launch (or a hand-started one):
    # it would keep the lock the agent's daemon needs.
    agent_loaded || tmux_daemon_stop "$BUCKLE_PIDFILE" "" buckle || true
    local rc=0
    install_plist || rc=$?
    [ "$rc" = 2 ] && return 1
    _launchd enable >/dev/null 2>&1 || true
    if agent_loaded; then
      # A changed plist reaches launchd only through a fresh bootstrap.
      if [ "$rc" = 0 ]; then
        _launchd bootout >/dev/null 2>&1 || true
        _launchd bootstrap || return 1
      else
        _launchd kickstart || return 1
      fi
    else
      _launchd bootstrap || return 1
    fi
  else
    # The daemon rotates and opens its own log as its first argument; the
    # detacher's output would truncate the previous life's log before it could.
    tmux_tmuxd_detach "$BUCKLE_DIR" /dev/null ./buckle \
      --log "$BUCKLE_LOG" --pidfile "$BUCKLE_PIDFILE" --settings "$BUCKLE_SETTINGS" >/dev/null || return 1
  fi
  wait_live || printf 'bucklespring: no live holder a second after launch; see %s\n' "$BUCKLE_LOG" >&2
  return 0
}

# Stop the daemon and keep it stopped. On macOS a disabled agent also stays down
# at the next login; a holder launchd never knew is stopped by its pidfile.
stop_daemon() {
  if owns_launchd; then
    _launchd bootout >/dev/null 2>&1 || true
    _launchd disable >/dev/null 2>&1 || true
  fi
  tmux_daemon_stop "$BUCKLE_PIDFILE" "" buckle || true
}

# New code for a live daemon: the binary is newer than the holder's claim.
holder_is_stale() {
  [ "$BUCKLE_DIR/buckle" -nt "$BUCKLE_PIDFILE" ]
}

relaunch() {
  if owns_launchd && agent_loaded; then
    _launchd kickstart >/dev/null 2>&1 || true
    wait_live || true
  else
    tmux_daemon_stop "$BUCKLE_PIDFILE" "" buckle || true
    launch || true
  fi
}

# ---------------------------------------------------------------------------
# Building and signing.

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

# Only a current binary is launched: the daemon's argv contract moves with its
# sources, and a binary that refuses it would, under launchd, restart every five
# seconds. An interactive caller builds in a popup; an unattended one (init,
# attach, restore) never opens one and builds quietly into the build log.
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

sign_identity_exists() {
  security find-identity -v -p codesigning 2>/dev/null | rg -Fq "\"$BUCKLE_SIGN_NAME\""
}

# Sign with the host's local identity when it exists: the Input Monitoring grant
# is keyed on the signature, and an ad-hoc one changes with every rebuild. A copy
# is signed and renamed into place, so a running daemon's executable is untouched.
sign_binary() { # directory
  darwin || return 0
  sign_identity_exists || return 0
  local bin="$1/buckle" tmp="$1/buckle.signing.$$"
  if cp -p "$bin" "$tmp" && codesign -f -s "$BUCKLE_SIGN_NAME" --identifier "$BUCKLE_LABEL" "$tmp" \
      && mv -f "$tmp" "$bin"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

_build() {                               # directory
  # The Mac build links system frameworks only (the native CoreAudio backend),
  # so there is no dependency setup to run first.
  (cd "$1" && make) && sign_binary "$1"
}

build_popup() {                          # internal popup-body arm
  local dir=${1:?missing build directory} rc=0
  _build "$dir" || rc=$?
  printf '\npress any key to close\n'
  IFS= read -rsn1 _ || true
  exit "$rc"
}

# Create this host's self-signed code-signing identity in the login keychain, once.
# Interactive by nature: trusting a certificate asks for an administrator, and
# codesign may ask once for the key (choose Always Allow). Rebuilds then keep the
# Input Monitoring grant.
do_sign_identity() {
  darwin || { printf 'bucklespring: signing identities are a macOS concern\n' >&2; return 2; }
  if sign_identity_exists; then
    printf 'bucklespring: "%s" already exists\n' "$BUCKLE_SIGN_NAME"
    return 0
  fi
  local dir keychain rc=0
  keychain=$(security default-keychain -d user 2>/dev/null | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//') || keychain=""
  [ -n "$keychain" ] || { printf 'bucklespring: no default keychain\n' >&2; return 1; }
  dir=$(mktemp -d) || return 1
  printf '%s\n' '[req]' 'distinguished_name = dn' 'x509_extensions = ext' 'prompt = no' \
    '[dn]' "CN = $BUCKLE_SIGN_NAME" \
    '[ext]' 'basicConstraints = critical,CA:FALSE' 'keyUsage = critical,digitalSignature' \
    'extendedKeyUsage = critical,codeSigning' > "$dir/req.cnf"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$dir/req.cnf" \
      -keyout "$dir/key.pem" -out "$dir/cert.pem" >/dev/null 2>&1 \
    && security import "$dir/key.pem" -k "$keychain" -T /usr/bin/codesign \
    && security import "$dir/cert.pem" -k "$keychain" \
    && security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$dir/cert.pem" \
    || rc=$?
  rm -rf "$dir"
  if [ "$rc" != 0 ]; then
    printf 'bucklespring: creating the signing identity failed (rc %s)\n' "$rc" >&2
    return "$rc"
  fi
  # The key's partition list lets codesign use it without a prompt; it needs the
  # keychain password, so a refusal here only means one prompt at the first build.
  security set-key-partition-list -S apple-tool:,apple: -s -D "$BUCKLE_SIGN_NAME" "$keychain" >/dev/null 2>&1 \
    || printf 'bucklespring: codesign may ask once for keychain access; choose Always Allow\n'
  printf 'bucklespring: created "%s"; the next build signs with it\n' "$BUCKLE_SIGN_NAME"
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
  # A live daemon takes the new profile at its next click; a rebuild restarts it.
  if is_running; then
    if holder_is_stale; then relaunch; else signal_holder; fi
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
    # is relaunched below; a build that fails leaves a live daemon alone.
    ensure_binary quiet || true
    if ! is_running; then
      launch || true
    elif holder_is_stale && binary_current; then
      relaunch
    elif owns_launchd && ! agent_loaded; then
      # A daemon from before the LaunchAgent: hand it to launchd.
      launch || true
    elif [ "$changed" = 1 ]; then
      signal_holder
    fi
  elif is_running || { owns_launchd && agent_loaded; }; then
    # Off, yet a daemon runs: a login started an agent that was never disabled,
    # or a restore brought back a server whose intent says off.
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

# Purge removes the plist (a `durable` row); unload the agent before the file goes.
do_purge() {
  stop_daemon
}

# The daemon's cell is the one judge of a refused keyboard tap; the menu and the
# doctor read its published verdict instead of parsing the log a second time.
denied_published() {
  local published
  published="$(tmux show -gqv @buckle_icon_color 2>/dev/null)" || return 1
  [ -n "$published" ] && [ "$published" = "${TMUX_ORANGE}${TMUX_BUCKLE_ICON}${TMUX_RESET}" ]
}

# One-click fix affordance for the permission menu row: under launchd the grant
# belongs to buckle itself, in Input Monitoring.
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
  if darwin; then
    if [ ! -f "$BUCKLE_PLIST" ]; then
      printf 'INFO bucklespring: no LaunchAgent at %s\n' "$BUCKLE_PLIST"
    elif agent_loaded; then
      printf 'INFO bucklespring: LaunchAgent %s is loaded\n' "$BUCKLE_LABEL"
    else
      printf 'INFO bucklespring: LaunchAgent %s is not loaded\n' "$BUCKLE_LABEL"
    fi
    if sign_identity_exists; then
      printf 'INFO bucklespring: signing identity "%s" exists\n' "$BUCKLE_SIGN_NAME"
    else
      printf 'INFO bucklespring: no signing identity; every rebuild asks for Input Monitoring again (run plugin.sh sign-identity once)\n'
    fi
  fi
  if [ -f "$BUCKLE_CACHE_DIR/render.hb" ]; then
    age=$(( $(date +%s) - $(tmux_get_mtime "$BUCKLE_CACHE_DIR/render.hb") ))
    printf 'INFO bucklespring: audio heartbeat %ss old\n' "$age"
  fi
  if denied_published; then
    printf 'FAIL bucklespring: the keyboard tap is refused; grant buckle Input Monitoring (the menu opens the pane)\n'
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
  purge)         do_purge ;;          # the declared cache and plist removal is core-owned
  doctor)        do_doctor ;;
  attach)        reconcile_intent ;;  # Linux has no supervisor: attach restarts a dead daemon
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
  sign-identity) do_sign_identity ;;
  *)             printf 'Usage: plugin.sh init|teardown|purge|doctor|attach|menu|start|stop|toggle|gain|quiet-commit|menu-authority|profile-valid|restore|icon-refresh|open-perms|sign-identity\n'; exit 1 ;;
esac
