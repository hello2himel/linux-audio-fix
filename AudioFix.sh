#!/usr/bin/env bash
#
# AudioFix.sh v2.1.0 - Realtek HDA audio fix
#
# Fixes silent/crackling audio: unmutes outputs, turns off Auto-Mute,
# sends the codec init sequence, optionally makes it survive reboot.
# Repo: https://github.com/hello2himel/linux-audio-fix
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/hello2himel/linux-audio-fix/main/AudioFix.sh | bash -s -- [options]
#   ./AudioFix.sh [options]
#
# Examples:
#   ./AudioFix.sh                         # guided fix (recommended)
#   ./AudioFix.sh --dry-run               # preview, changes nothing
#   ./AudioFix.sh --yes                   # non-interactive, safe defaults
#   ./AudioFix.sh --restore               # undo: put back saved settings
#   ./AudioFix.sh --list-chips            # probe only, change nothing
#
set -Eeuo pipefail
# Secure PATH for root execs (pentest: PATH hijack via update-initramfs etc.)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

VERSION="2.1.0"

# ---------------------------------------------------------------------------
# Bash / env pre-flight
# ---------------------------------------------------------------------------
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "ERROR: This script requires bash 4+ (associative arrays, mapfile). Your bash: ${BASH_VERSION:-unknown}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
NO_REBOOT=0
DO_REBOOT=0
VERBOSE=0
QUIET=0
NO_COLOR_FLAG=0
PLAIN=0
FORCE=0
LIST_CHIPS_ONLY=0
UNINSTALL=0
RESTORE=0
RESTORE_DIR=""
APPLY_VERBS_ONLY=0
OVERRIDE_CARD=""
OVERRIDE_CHIP=""
PERSIST="prompt"          # prompt|yes|no
PERSIST_MODE="both"       # modprobe|systemd|both
BACKUP_DIR=""
BACKUP_ROOT=""
LOG_FILE_OVERRIDE=""
SUDO_KEEPALIVE_PID=""
MODEL=""; CARD_NUM=""; CODEC_NUM=""; IFACE=""; SELECTED_INDEX=0
HDA_DEV_USED=""
VERBS_OK=0; VERBS_TOTAL=4
AUTOMUTE_DONE=0; AUTOMUTE_TOTAL=0
UNMUTED_LIST=""
WANT_REBOOT="N"
HEARD=""
SOUND_SERVER=""
LOCK_DIR="/tmp/audiofix.lock"
LOCK_CREATED=0

EXIT_OK=0
EXIT_ENV=1
EXIT_USAGE=2
EXIT_PKG=3
EXIT_ROOT=4
EXIT_HW=5
EXIT_VERIFY=6
EXIT_ABORT=130
# Back-compat aliases for old names used in a few places.
EXIT_NO_CHIP=$EXIT_HW
JSON=0
JSON_STATUS="error"
JSON_DETAIL=""
JSON_EMITTED=0

# ---------------------------------------------------------------------------
# Help / version
# ---------------------------------------------------------------------------
print_help() {
  cat <<EOF
AudioFix v${VERSION} - fix silent or crackling audio on Linux

Usage
  $0 [options]

Common
  -y, --yes          Don't ask questions, use recommended answers
  -n, --dry-run      Show what would change, change nothing
      --restore      Undo the last fix

More
  --list-chips       Show audio chips and exit
  --card N           Use sound card N
  --chip MODEL       Assume chip MODEL (needs --force if unknown)
  --force            Allow unknown chips (you confirm first)
  --reboot           Restart automatically at the end
  --no-reboot        Never restart
  --persist          Keep the fix after restart
  --no-persist       Temporary fix, lost on restart
  --persist-mode M   modprobe|systemd|both (default: both)
  --backup-dir DIR   Where to keep backups
  --uninstall        Remove the permanent fix, restore backup
  -v, --verbose      Show every command that runs
  -q, --quiet        Only errors (silent on success)
      --no-color     Disable colors (also honors NO_COLOR)
      --json         Machine-readable result on stdout
  --log-file PATH    Custom log path
  -h, --help         Show this help
      --version      Show version

Exit codes: 0 fixed | 1 error | 2 bad flags | 3 install failed |
            4 needs root | 5 unsupported hardware | 6 no sound heard |
            130 stopped by you

Examples
  $0                    Guided fix
  $0 --dry-run          Preview only
  $0 --restore          Put things back

Docs and issues: https://github.com/hello2himel/linux-audio-fix
EOF
}

# ---------------------------------------------------------------------------
# Arg parsing (manual long-opt, supports --opt val and --opt=val)
# ---------------------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) print_help; exit 0 ;;
      --version) echo "AudioFix v${VERSION}"; exit 0 ;;
      -n|--dry-run) DRY_RUN=1; NO_REBOOT=1; shift ;;
      -y|--yes|--assume-yes) ASSUME_YES=1; shift ;;
      --no-reboot) NO_REBOOT=1; shift ;;
      --reboot) DO_REBOOT=1; shift ;;
      -v|--verbose) VERBOSE=1; shift ;;
      -q|--quiet) QUIET=1; shift ;;
      --no-color) NO_COLOR_FLAG=1; shift ;;
      --json) JSON=1; QUIET=1; shift ;;
      --plain|--no-tui) PLAIN=1; shift ;;
      --force) FORCE=1; shift ;;
      --list-chips|--list) LIST_CHIPS_ONLY=1; shift ;;
      --uninstall) UNINSTALL=1; shift ;;
      --restore) RESTORE=1; shift ;;
      --restore=*) RESTORE=1; RESTORE_DIR="${1#*=}"; shift ;;
      --apply-verbs-only) APPLY_VERBS_ONLY=1; shift ;;
      --persist) PERSIST="yes"; shift ;;
      --no-persist) PERSIST="no"; shift ;;
      --persist-mode)
        [ $# -ge 2 ] || { echo "ERROR: --persist-mode needs a value (modprobe|systemd|both)" >&2; exit "$EXIT_USAGE"; }
        PERSIST_MODE="$2"; shift 2 ;;
      --persist-mode=*)
        [ -n "${1#*=}" ] || { echo "ERROR: --persist-mode= needs a value" >&2; exit "$EXIT_USAGE"; }
        PERSIST_MODE="${1#*=}"; shift ;;
      --card)
        [ $# -ge 2 ] || { echo "ERROR: --card needs a number" >&2; exit "$EXIT_USAGE"; }
        OVERRIDE_CARD="$2"; shift 2 ;;
      --card=*)
        [ -n "${1#*=}" ] || { echo "ERROR: --card= needs a number" >&2; exit "$EXIT_USAGE"; }
        OVERRIDE_CARD="${1#*=}"; shift ;;
      --chip)
        [ $# -ge 2 ] || { echo "ERROR: --chip needs a value (e.g. ALC256)" >&2; exit "$EXIT_USAGE"; }
        OVERRIDE_CHIP="$2"; shift 2 ;;
      --chip=*)
        [ -n "${1#*=}" ] || { echo "ERROR: --chip= needs a value" >&2; exit "$EXIT_USAGE"; }
        OVERRIDE_CHIP="${1#*=}"; shift ;;
      --backup-dir)
        [ $# -ge 2 ] || { echo "ERROR: --backup-dir needs a directory" >&2; exit "$EXIT_USAGE"; }
        BACKUP_DIR="$2"; shift 2 ;;
      --backup-dir=*)
        [ -n "${1#*=}" ] || { echo "ERROR: --backup-dir= needs a directory" >&2; exit "$EXIT_USAGE"; }
        BACKUP_DIR="${1#*=}"; shift ;;
      --log-file)
        [ $# -ge 2 ] || { echo "ERROR: --log-file needs a path" >&2; exit "$EXIT_USAGE"; }
        LOG_FILE_OVERRIDE="$2"; shift 2 ;;
      --log-file=*)
        [ -n "${1#*=}" ] || { echo "ERROR: --log-file= needs a path" >&2; exit "$EXIT_USAGE"; }
        LOG_FILE_OVERRIDE="${1#*=}"; shift ;;
      --) shift; break ;;
      -*) echo "ERROR: unknown option: $1 (see --help)" >&2; exit "$EXIT_USAGE" ;;
      *) echo "ERROR: unexpected argument: $1 (see --help)" >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  if [ $# -gt 0 ]; then
    echo "ERROR: unexpected argument: $1 (see --help)" >&2; exit "$EXIT_USAGE"
  fi

  case "$PERSIST_MODE" in
    modprobe|systemd|both) ;;
    *) echo "ERROR: --persist-mode must be modprobe|systemd|both" >&2; exit "$EXIT_USAGE" ;;
  esac
  if [ -n "$OVERRIDE_CARD" ] && ! [[ "$OVERRIDE_CARD" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --card must be a number, got: $OVERRIDE_CARD" >&2
    exit "$EXIT_USAGE"
  fi
}

# ---------------------------------------------------------------------------
# Colors / markers (isatty + NO_COLOR + UTF-8 aware; log file stays ASCII)
# ---------------------------------------------------------------------------
USE_COLOR=0
USE_UTF8=0
C_RESET=""; C_BOLD=""; C_DIM=""; C_ACCENT=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""; C_WHITE=""
M_OK="[ok]"; M_FAIL="[fail]"; M_WARN="[warn]"; M_BULLET="-"; M_ASK="?"; M_SKIP="[skip]"; M_SUB="->"
init_colors() {
  if [ "$NO_COLOR_FLAG" -eq 1 ] || [ -n "${NO_COLOR:-}" ]; then USE_COLOR=0; else
    if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ] && [ -t 1 ] && command -v tput &>/dev/null; then
      if tput colors &>/dev/null && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
        USE_COLOR=1
        C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
        C_ACCENT=$'\e[36m'
        C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
        C_BLUE=$'\e[36m'; C_CYAN=$'\e[36m'; C_MAGENTA=$'\e[35m'; C_WHITE=$'\e[37m'
      fi
    fi
    if [ "$USE_COLOR" -eq 0 ] && [ -n "${CLICOLOR_FORCE:-}" ] && [ "${CLICOLOR_FORCE}" != "0" ]; then
      USE_COLOR=1
      C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
      C_ACCENT=$'\e[36m'
      C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
      C_BLUE=$'\e[36m'; C_CYAN=$'\e[36m'; C_MAGENTA=$'\e[35m'; C_WHITE=$'\e[37m'
    fi
  fi
  # UTF-8 markers only when the locale supports them; else ASCII fallback.
  local codeset="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [[ "$codeset" =~ [Uu][Tt][Ff]-?8 ]]; then
    USE_UTF8=1
  elif [ "$(locale charmap 2>/dev/null || echo ASCII)" = "UTF-8" ]; then
    USE_UTF8=1
  fi
  if [ "$USE_UTF8" -eq 1 ]; then
    M_OK="✔"; M_FAIL="✖"; M_WARN="!"; M_BULLET="•"; M_ASK="?"; M_SKIP="–"; M_SUB="↳"
  else
    M_OK="[ok]"; M_FAIL="[fail]"; M_WARN="[warn]"; M_BULLET="-"; M_ASK="?"; M_SKIP="[skip]"; M_SUB="->"
  fi
}

LOG_FILE=""
init_log() {
  local _log_ok _logroot _canon
  if [ -n "$LOG_FILE_OVERRIDE" ]; then
    _log_ok=0
    _canon="$(canon_path "$LOG_FILE_OVERRIDE")"
    case "$_canon" in
      /tmp/*|/var/tmp/*|/var/log/*|/var/lib/audiofix/*) _log_ok=1 ;;
    esac
    if [ -n "${HOME:-}" ]; then
      case "$_canon" in "${HOME}"/.local/state/audiofix/*) _log_ok=1 ;; esac
    fi
    if [ "$_log_ok" -eq 0 ]; then
      echo "ERROR: --log-file must be under /tmp, /var/tmp, /var/log, /var/lib/audiofix, or ~/.local/state/audiofix" >&2
      exit "$EXIT_USAGE"
    fi
    [ -L "$LOG_FILE_OVERRIDE" ] && { echo "ERROR: --log-file must not be a symlink" >&2; exit "$EXIT_ENV"; }
    LOG_FILE="$LOG_FILE_OVERRIDE"
    : > "$LOG_FILE" 2>/dev/null || { echo "ERROR: cannot write log: $LOG_FILE" >&2; exit "$EXIT_ENV"; }
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  else
    _logroot="$(default_backup_root)"
    mkdir -p "$_logroot" 2>/dev/null || _logroot="/var/tmp"
    LOG_FILE=$(mktemp -p "$_logroot" audiofix.XXXXXX.log 2>/dev/null || mktemp /var/tmp/audiofix.XXXXXX.log 2>/dev/null || mktemp /tmp/audiofix.XXXXXX.log 2>/dev/null) || { echo "ERROR: cannot create log file" >&2; exit "$EXIT_ENV"; }
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  fi
  # prune logs older than 7 days (best effort)
  find /var/lib/audiofix /var/tmp /tmp "${HOME:-/nonexistent}/.local/state/audiofix" -maxdepth 1 -name 'audiofix.*.log' -mtime +7 -delete 2>/dev/null || true
}

log_plain() { printf '%s\n' "$1" >>"$LOG_FILE" 2>/dev/null || true; }
canon_path() {
  # Resolve .. and symlinks for allowlist checks (best effort).
  if command -v realpath &>/dev/null; then
    realpath -m -- "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}
log() {
  local msg="$1"
  printf '%b\n' "$msg" | tee -a "$LOG_FILE" >/dev/null 2>&1 || printf '%b\n' "$msg"
  if [ "$QUIET" -eq 0 ]; then printf '%b\n' "$msg"; fi
}
# --- Screen output: one marker set, one accent color ---
# Markers are UTF-8 when the locale supports them, ASCII otherwise.
# The log file always gets the ASCII form so it stays grep-friendly.
banner() {
  # Calm header. Tagline + version. Log path prints once at the end, not here.
  SECONDS=0
  log "${C_BOLD}AudioFix ${VERSION}${C_RESET} - fix silent or crackling audio on Linux"
  log_plain "AudioFix ${VERSION} - fix silent or crackling audio on Linux"
  if [ "$DRY_RUN" -eq 1 ]; then log "  Preview only - nothing will change"; log_plain "  Preview only"; fi
}
section() {
  # Short section header, always visible. One line, one accent color.
  local title="$1"
  log ""
  log "${C_BOLD}${C_ACCENT}${title}${C_RESET}"
  log_plain ""
  log_plain "== ${title} =="
}
step() {
  # Internal progress: log file always, screen only in --verbose.
  local title="$1"
  log_plain ">> ${title}"
  if [ "$VERBOSE" -eq 1 ]; then
    log ""
    log "${C_BOLD}${C_ACCENT}>> ${title}${C_RESET}"
  fi
}
info() { log "${C_ACCENT}  ${M_BULLET}${C_RESET} $1"; log_plain "  - $1"; }
ok()   { log "${C_GREEN}  ${M_OK}${C_RESET} $1"; log_plain "  [ok] $1"; }
warn() { local m="$1"; log "${C_YELLOW}  ${M_WARN}${C_RESET} $m"; log_plain "  [warn] $m"; }
err()  { local m="$1"; printf '%s\n' "  [fail] $m" >>"$LOG_FILE" 2>/dev/null || true; printf '%b\n' "${C_RED}  ${M_FAIL}${C_RESET} $m" >&2; if [ -z "$JSON_DETAIL" ]; then JSON_DETAIL="$m"; fi; }
die()  { err "$1"; exit "${2:-$EXIT_ENV}"; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r/\\r/g; s/\t/\\t/g' | tr '\n\r' '  ' | LC_ALL=C tr -d '\000-\010\013\014\016-\037'; }
json_emit() {
  [ "$JSON" -eq 1 ] || return 0
  [ "$JSON_EMITTED" -eq 0 ] || return 0
  JSON_EMITTED=1
  printf '{"version":"%s","status":"%s","detail":"%s","chip":"%s","card":"%s","persist":"%s","heard":"%s","reboot":"%s","log":"%s"}\n' \
    "$(json_escape "$VERSION")" "$(json_escape "$JSON_STATUS")" "$(json_escape "$JSON_DETAIL")" \
    "$(json_escape "$MODEL")" "$(json_escape "$CARD_NUM")" "$(json_escape "$PERSIST")" \
    "$(json_escape "$HEARD")" "$(json_escape "$WANT_REBOOT")" "$(json_escape "$LOG_FILE")"
}
# --- Visible prompt helper (root cause fix) ---
# Old bug: `read -rp "Q" v </dev/tty 2>/dev/null` hides the question,
# because read -p prints to stderr, which 2>/dev/null discards.
# So the script waited for Enter with nothing on screen.
# Fix: print with printf (stdout, always visible), then plain read (no -p).
can_prompt() {
  # true only when we may safely block for input
  if [ "$ASSUME_YES" -eq 1 ]; then return 1; fi
  if [ "$DRY_RUN" -eq 1 ]; then return 1; fi
  if [ "$QUIET" -eq 1 ]; then return 1; fi
  if [ ! -t 0 ]; then return 1; fi
  if [ ! -t 1 ]; then return 1; fi
  if [ ! -r /dev/tty ]; then return 1; fi
  return 0
}
ask() {
  # $1 = question text (no leading "?"), $2 = default, $3 = var name.
  # Prints visibly via /dev/tty. Echoes the default when Enter is empty
  # (typed input is already echoed by the terminal - never print it twice).
  local question="$1" def="$2" __var="$3"
# NOTE: internal buffer is _ans on purpose: with bash dynamic scope,
# printf -v "$__var" would otherwise write our own local instead of
# the caller variable, and every answer would be lost.
  local _ans="" typed_empty=0
  printf '%b?%b %s ' "$C_ACCENT" "$C_RESET" "$question" > /dev/tty 2>/dev/null \
    || printf '? %s ' "$question"
  log_plain "ASK: $question (default=${def})"
  if ! IFS= read -r -t 60 _ans </dev/tty; then _ans=""; fi
  if [ -z "$_ans" ]; then
    typed_empty=1
    printf '%s\n' "$def" > /dev/tty 2>/dev/null || true
  fi
  _ans="${_ans:-$def}"
  printf -v "$__var" '%s' "$_ans"
  if [ "$typed_empty" -eq 1 ]; then
    log "  Chose: $_ans (default)"
  fi
  log_plain "CHOSE: $_ans"
}
# --- Plain prompts only (no external TUI deps by design) ---
# gum/fzf/dialog intentionally not used: keep curl|bash predictable.
confirm_yn() {
  # $1 = question, $2 = default Y/N. Returns 0=yes, 1=no. Pure bash.
  # Accepts y/yes/n/no, re-asks anything else (max 3 tries, then default).
  local question="$1" def="$2" ans="" tries=0
  while [ "$tries" -lt 3 ]; do
    ask "$question" "$def" ans
    case "$ans" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *)
        log "? Please answer y or n."
        tries=$((tries + 1))
        ;;
    esac
  done
  case "$def" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "  (dry-run) would run: $*"
    log_plain "  (dry-run) would run: $*"
    return 0
  fi
  if [ "$VERBOSE" -eq 1 ]; then
    log "  \$ $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local code="${PIPESTATUS[0]}"
    return "$code"
  else
    "$@" >>"$LOG_FILE" 2>&1
    return $?
  fi
}
run_spin() {
  # Calm waiting line: one static message, no flickering frames.
  # Output goes to log; screen shows a single line (verbose streams live).
  local msg="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    log "  (dry-run) would run: $*"
    log_plain "  (dry-run) would run: $*"
    return 0
  fi
  if [ "$VERBOSE" -eq 1 ]; then
    log "  \$ $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
  fi
  if [ "$QUIET" -eq 0 ]; then log "  ... $msg"; fi
  log_plain "START: $msg ($*)"
  "$@" >>"$LOG_FILE" 2>&1
  local code=$?
  log_plain "END($code): $msg"
  return "$code"
}

# ---------------------------------------------------------------------------
# Sudo handling (root-aware, no sudo when already root)
# ---------------------------------------------------------------------------
SUDO=""
init_sudo() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    SUDO=""
    return 0
  fi
  if ! command -v sudo &>/dev/null; then
    die "No administrator rights. This fix changes system audio settings. Ask an administrator, or re-run as root." "$EXIT_ROOT"
  fi
  if [ "$DRY_RUN" -eq 0 ] && [ "$LIST_CHIPS_ONLY" -eq 0 ]; then
    info "This fix changes system audio settings, so it needs administrator rights once."
    if ! sudo -v; then
      die "Could not get administrator rights. Nothing was changed. Ask an administrator, or re-run as root." "$EXIT_ROOT"
    fi
    ( while true; do sudo -v; sleep 60; done ) &
    SUDO_KEEPALIVE_PID=$!
  fi
  SUDO="sudo"
}
acquire_lock() {
  if [ -L "$LOCK_DIR" ]; then
    die "Refusing unsafe lock path (symlink): $LOCK_DIR" "$EXIT_ENV"
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "Another AudioFix run is in progress. If that is wrong, remove $LOCK_DIR and try again." "$EXIT_ENV"
  fi
  LOCK_CREATED=1
}
cleanup() {
  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi
  if [ "$LOCK_CREATED" -eq 1 ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_CREATED=0
  fi
  json_emit
}
on_interrupt() {
  JSON_STATUS="aborted"
  JSON_DETAIL="Stopped by user"
  cleanup
  trap - EXIT INT TERM HUP
  err "Stopped. Your sound settings may be half-applied."
  if [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR" ]; then
    err "Undo with: $0 --restore \"$BACKUP_DIR\""
  else
    err "Run again to retry, or restore a backup from a previous run."
  fi
  exit "$EXIT_ABORT"
}
stop_keepalive() {
  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi
}

# ---------------------------------------------------------------------------
# Chip database (normalized MODEL -> interface / quirk hint / description)
# HDA = hda-verb meaningful. USB/SOF = hda-verb NOT applicable.
# ---------------------------------------------------------------------------
normalize_model() {
  # Uppercase, extract first ALCxxx / RTxxx / ALCSxxx token
  local raw="$1"
  local up
  up=$(printf '%s' "$raw" | LC_ALL=C tr '[:lower:]' '[:upper:]')
  local tok
  tok=$(printf '%s' "$up" | grep -oE 'ALCS?[0-9]+[A-Z]*|RT[0-9]+[A-Z]*' | head -n1 || true)
  if [ -n "$tok" ]; then
    # Canonicalize known aliases
    case "$tok" in
      ALCS1220A|ALCS1200A) echo "ALC1220" ;;
      ALC1220P) echo "ALC1220" ;;
      ALC897P) echo "ALC897" ;;
      ALC271X) echo "ALC271" ;;
      ALC272X|ALC273X) echo "${tok%X}" ;;
      ALC861VD) echo "ALC861" ;;
      *) echo "$tok" ;;
    esac
    return 0
  fi
  # Fallback: stripped uppercase alnum+dashes
  printf '%s' "$up" | LC_ALL=C tr -cd 'A-Z0-9-' | head -c 24
}

chip_iface() {
  # echo HDA|USB|SOF|UNKNOWN
  case "$1" in
    ALC4080|ALC4082|ALC4040|ALC4050|ALC4070) echo "USB" ;;
    RT5682|RT5682S|RT715|RT714|RT1318|ALC1318|RT1320|RT722) echo "SOF" ;;
    ALC221|ALC231|ALC233|ALC234|ALC235|ALC236|ALC245|ALC255|ALC256|ALC257|ALC259|\
ALC260|ALC262|ALC267|ALC268|ALC269|ALC270|ALC271|ALC272|ALC273|ALC274|ALC275|ALC276|\
ALC280|ALC282|ALC283|ALC284|ALC285|ALC286|ALC287|ALC288|ALC289|ALC290|ALC292|ALC293|\
ALC294|ALC295|ALC298|ALC299|ALC300|ALC215|ALC225|ALC230|ALC3246|ALC3253|ALC3254|\
ALC3234|ALC3220|ALC3204|ALC700|ALC660|ALC861|ALC867|ALC662|ALC663|ALC665|ALC668|\
ALC670|ALC671|ALC672|ALC676|ALC680|ALC891|ALC880|ALC882|ALC883|ALC885|ALC887|ALC888|\
ALC889|ALC892|ALC898|ALC899|ALC1150|ALC1220|ALC1250|ALC897|ALC1200|ALC3306) echo "HDA" ;;
    *) echo "UNKNOWN" ;;
  esac
}

chip_model_hint() {
  # Suggested snd-hda-intel model= options (first choice is safest)
  case "$1" in
    ALC255|ALC3234) echo "auto, alc255-acer, alc255-asus, alc255-dell1, alc255-dell-headset" ;;
    ALC256|ALC3246) echo "auto, alc256-asus-mic, alc256-samsung-headphone" ;;
    ALC257) echo "auto, lenovo-spk-noise, thinkpad" ;;
    ALC269|ALC270|ALC272|ALC273|ALC276) echo "auto, alc269-dmic, asus-zenbook, lenovo-dock, tpt440" ;;
    ALC236) echo "auto, hp-gpio-led (HP ProBook mute-LED)" ;;
    ALC245) echo "auto + check CS35L41 amp quirk" ;;
    ALC274|ALC3254) echo "auto, alc274-dell-aio" ;;
    ALC285) echo "auto, alc285-hp-amp-init (ASUS ROG/HP + CS35L41 check)" ;;
    ALC287|ALC3306) echo "auto, thinkpad; if Legion/Yoga + 2-of-4 speakers see CS35L41/SOF note" ;;
    ALC288) echo "auto, alc288-dell1, alc288-dell-xps13" ;;
    ALC293) echo "auto, alc293-dell1" ;;
    ALC294) echo "auto, alc294-lenovo-mic" ;;
    ALC295|ALC3253) echo "auto, alc295-disable-dac3, alc295-hp-x360" ;;
    ALC298|ALC3220|ALC3204) echo "auto, alc298-dell1, alc298-spk-volume" ;;
    ALC292) echo "auto (Dell ALC3220 branding = same silicon)" ;;
    ALC280) echo "auto, alc280-hp-headset" ;;
    ALC283) echo "auto, alc283-headset, alc283-sense-combo" ;;
    ALC662|ALC663|ALC665|ALC668|ALC670|ALC671|ALC672|ALC676|ALC891) echo "auto, dual-codecs, alc662-headset" ;;
    ALC680) echo "auto" ;;
    ALC882|ALC883|ALC885|ALC887|ALC888|ALC889|ALC892|ALC898|ALC899|ALC1150|ALC1220|ALC1250|ALC897|ALC1200) echo "auto, dual-codecs (desktop HDA)" ;;
    ALC4080|ALC4082) echo "N/A (USB: fix via UCM profile, not model=)" ;;
    *) echo "auto, generic" ;;
  esac
}



# Generic EAPD/coef init verbs (original fix). Volatile - needs persistence.
GENERIC_VERBS=("0x20 0x500 0x1b" "0x20 0x477 0x4a4b" "0x20 0x500 0xf" "0x20 0x477 0x74")

# ---------------------------------------------------------------------------
# OS / package management (no sourcing os-release, apt update once)
# ---------------------------------------------------------------------------
OS_ID=""; OS_LIKE=""; OS_PRETTY="Linux"; APT_UPDATED=0
detect_os() {
  if [ -f /etc/os-release ]; then
    OS_ID=$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | LC_ALL=C tr -d '"' | LC_ALL=C tr '[:upper:]' '[:lower:]' || true)
    OS_LIKE=$(grep -E '^ID_LIKE=' /etc/os-release 2>/dev/null | cut -d= -f2 | LC_ALL=C tr -d '"' | LC_ALL=C tr '[:upper:]' '[:lower:]' || true)
    OS_PRETTY=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | LC_ALL=C tr -d '"' || echo "Linux")
    if [ -z "$OS_PRETTY" ]; then OS_PRETTY="Linux"; fi
  fi
  return 0
}
install_hint() {
  # $1 = missing tool. Prints how to install it on this distro.
  case "${OS_LIKE} ${OS_ID}" in
    *arch*) echo "sudo pacman -S alsa-utils alsa-tools" ;;
    *debian*|*ubuntu*|*mint*|*pop*|*kali*|*raspbian*) echo "sudo apt-get install -y alsa-utils alsa-tools" ;;
    *fedora*|*rhel*|*centos*|*rocky*|*alma*) echo "sudo dnf install -y alsa-utils alsa-tools" ;;
    *suse*|*opensuse*) echo "sudo zypper install alsa-utils alsa-tools" ;;
    *) echo "install alsa-utils and alsa-tools with your package manager" ;;
  esac
}
detect_stack() {
  # PipeWire, PulseAudio, or bare ALSA. Best effort, never fails.
  if pgrep -x pipewire &>/dev/null || pgrep -x pipewire-pulse &>/dev/null; then
    SOUND_SERVER="PipeWire"
  elif pgrep -x pulseaudio &>/dev/null || command -v pactl &>/dev/null; then
    SOUND_SERVER="PulseAudio"
  else
    SOUND_SERVER="ALSA"
  fi
}

pkg_install() {
  # $1 = logical group: alsa-utils | alsa-tools | diag
  local group="$1"
  local pkgs=""
  local fam="${OS_LIKE} ${OS_ID}"
  case "$fam" in
    *arch*|*manjaro*|*endeavour*)
      case "$group" in
        alsa-utils) pkgs="alsa-utils alsa-ucm-conf" ;;
        alsa-tools) pkgs="alsa-tools" ;;
        diag) pkgs="pciutils usbutils" ;;
      esac
      # shellcheck disable=SC2086
      run_spin "Installing $pkgs (pacman)..." $SUDO pacman -Sy --needed --noconfirm $pkgs ;;
    *debian*|*ubuntu*|*mint*|*pop*|*kali*|*raspbian*|*rasbian*)
      case "$group" in
        alsa-utils) pkgs="alsa-utils alsa-ucm-conf" ;;
        alsa-tools) pkgs="alsa-tools" ;;
        diag) pkgs="pciutils usbutils" ;;
      esac
      if [ "$APT_UPDATED" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        run_spin "Updating package lists (apt-get update)..." $SUDO apt-get update -qq || warn "apt-get update failed, trying install anyway"
        APT_UPDATED=1
      elif [ "$DRY_RUN" -eq 1 ]; then
        log "  (dry-run) would run: $SUDO apt-get update -qq"
      fi
      # shellcheck disable=SC2086
      run_spin "Installing $pkgs (apt)..." $SUDO apt-get install -y $pkgs ;;
    *fedora*|*rhel*|*centos*|*rocky*|*alma*|*nobara*)
      case "$group" in
        alsa-utils) pkgs="alsa-utils alsa-ucm" ;;
        alsa-tools) pkgs="alsa-tools" ;;
        diag) pkgs="pciutils usbutils" ;;
      esac
      if command -v dnf &>/dev/null; then run_spin "Installing $pkgs (dnf)..." $SUDO dnf install -y $pkgs
      else run_spin "Installing $pkgs (yum)..." $SUDO yum install -y $pkgs; fi ;;
    *suse*|*opensuse*|*sles*)
      case "$group" in
        alsa-utils) pkgs="alsa-utils alsa-ucm-conf" ;;
        alsa-tools) pkgs="alsa-tools" ;;
        diag) pkgs="pciutils usbutils" ;;
      esac
      # shellcheck disable=SC2086
      run_spin "Installing $pkgs (zypper)..." $SUDO zypper --non-interactive install $pkgs ;;
    *gentoo*)
      case "$group" in
        alsa-utils) pkgs="media-sound/alsa-utils" ;;
        alsa-tools) pkgs="media-sound/alsa-tools" ;;
        diag) pkgs="sys-apps/pciutils sys-apps/usbutils" ;;
      esac
      # shellcheck disable=SC2086
      # shellcheck disable=SC2086
      run_spin "Installing $pkgs (emerge)..." $SUDO emerge --ask=n $pkgs ;;
    *alpine*)
      case "$group" in
        alsa-utils) pkgs="alsa-utils alsa-ucm-conf" ;;
        alsa-tools) pkgs="alsa-tools" ;;
        diag) pkgs="pciutils usbutils" ;;
      esac
      # shellcheck disable=SC2086
      run_spin "Installing $pkgs (apk)..." $SUDO apk add $pkgs ;;
    *void*)
      case "$group" in
        alsa-utils) pkgs="alsa-utils" ;;
        alsa-tools) pkgs="alsa-tools" ;;
        diag) pkgs="pciutils usbutils" ;;
      esac
      # shellcheck disable=SC2086
      run_spin "Installing $pkgs (xbps)..." $SUDO xbps-install -Sy $pkgs ;;
    *nixos*)
      die "NixOS detected: cannot imperatively install. Add to environment.systemPackages: alsa-utils alsa-tools alsa-ucm-conf pciutils usbutils" "$EXIT_PKG" ;;
    *)
      warn "Unknown distro, trying standard tools..."
      log_plain "distro: ID=${OS_ID:-?} LIKE=${OS_LIKE:-?}"
      if [ "$VERBOSE" -eq 1 ]; then info "Distro IDs: ${OS_ID:-?} / ${OS_LIKE:-?}"; fi
      if command -v pacman &>/dev/null; then run $SUDO pacman -Sy --needed --noconfirm alsa-utils alsa-tools && return 0 || true; fi
      if command -v apt-get &>/dev/null; then run $SUDO apt-get install -y alsa-utils alsa-tools && return 0 || true; fi
      if command -v dnf &>/dev/null; then run $SUDO dnf install -y alsa-utils alsa-tools && return 0 || true; fi
      if command -v zypper &>/dev/null; then run $SUDO zypper --non-interactive install alsa-utils alsa-tools && return 0 || true; fi
      if command -v apk &>/dev/null; then run $SUDO apk add alsa-utils alsa-tools && return 0 || true; fi
      if command -v xbps-install &>/dev/null; then run $SUDO xbps-install -Sy alsa-utils alsa-tools && return 0 || true; fi
      return 1 ;;
  esac
}

ensure_deps() {
  detect_os
  detect_stack
  if ! command -v alsamixer &>/dev/null; then
    info "Installing sound tools..."
    pkg_install alsa-utils || die "Could not install sound tools. They change mixer settings like Auto-Mute. Try: $(install_hint alsamixer)" "$EXIT_PKG"
    if ! command -v alsamixer &>/dev/null && [ "$DRY_RUN" -eq 0 ]; then
      die "Install finished but alsamixer is still missing. Try: $(install_hint alsamixer)" "$EXIT_PKG"
    fi
  fi
  if ! command -v hda-verb &>/dev/null; then
    info "Installing chip tools..."
    pkg_install alsa-tools || die "Could not install chip tools. They send startup commands to the audio chip. Try: $(install_hint hda-verb)" "$EXIT_PKG"
    if ! command -v hda-verb &>/dev/null && [ "$DRY_RUN" -eq 0 ]; then
      die "Couldn't find hda-verb. It's needed to talk to the audio chip. Install it: $(install_hint hda-verb)" "$EXIT_PKG"
    fi
  fi
  # diag tools are best-effort (detection still works without them)
  if ! command -v lspci &>/dev/null || ! command -v lsusb &>/dev/null; then
    pkg_install diag || { if [ "$VERBOSE" -eq 1 ]; then warn "Extra detection tools unavailable; using fallbacks"; fi; }
  fi
}

# ---------------------------------------------------------------------------
# Detection (no grep -P; LC_ALL=C for locale-stable parsing)
# ---------------------------------------------------------------------------
FOUND_CARDS=()
FOUND_CODECS=()
FOUND_MODELS=()
FOUND_IFACES=()
FOUND_METHOD=""
USB_HINT=""
SOF_HINT=""

detect_chips() {
  step "Detecting audio chip"
  FOUND_CARDS=(); FOUND_CODECS=(); FOUND_MODELS=(); FOUND_IFACES=(); FOUND_METHOD=""

  # 1) Authoritative: /proc/asound/card*/codec#*
  local _nullglob_was_off=0
  shopt -q nullglob || _nullglob_was_off=1
  shopt -s nullglob
  local codec_files=(/proc/asound/card*/codec#*)
  if [ "$_nullglob_was_off" -eq 1 ]; then shopt -u nullglob; fi
  if [ "${#codec_files[@]}" -gt 0 ]; then
    for codec_path in "${codec_files[@]}"; do
      [ -f "$codec_path" ] || continue
      local vendor_line codec_line vendor_hex codec_tok model iface
      vendor_line=$(grep -m1 -i "Vendor Id" "$codec_path" 2>/dev/null || true)
      codec_line=$(grep -m1 -i "Codec:" "$codec_path" 2>/dev/null || true)
      vendor_hex=$(printf '%s' "$vendor_line" | grep -oE '0x[0-9a-fA-F]+' | head -n1 | LC_ALL=C tr '[:upper:]' '[:lower:]' || true)
      local is_rt=0
      if [[ "$vendor_hex" == 0x10ec* ]]; then is_rt=1
      elif printf '%s' "$codec_line" | grep -qi "realtek"; then is_rt=1
      fi
      if [ "$is_rt" -eq 1 ]; then
        codec_tok=$(printf '%s' "$codec_line" | grep -oE 'ALCS?[0-9]+[A-Za-z]*|RT[0-9]+[A-Za-z]*' | head -n1 || true)
        [ -z "$codec_tok" ] && codec_tok="unknown-model"
        model=$(normalize_model "$codec_tok")
        iface=$(chip_iface "$model")
        if [ "$iface" = "UNKNOWN" ] && [ "$model" != "UNKNOWN-MODEL" ]; then
          # Unknown ALC/RT token: still HDA if vendor is 10ec, but flag for --force
          if [[ "$vendor_hex" == 0x10ec* ]]; then iface="HDA"; fi
        fi
        if [[ "$codec_path" =~ card([0-9]+)/codec#([0-9]+) ]]; then
          FOUND_CARDS+=("${BASH_REMATCH[1]}")
          FOUND_CODECS+=("${BASH_REMATCH[2]}")
          FOUND_MODELS+=("$model")
          FOUND_IFACES+=("$iface")
        fi
      fi
    done
    if [ "${#FOUND_MODELS[@]}" -gt 0 ]; then FOUND_METHOD="proc-asound (high confidence)"; fi
  fi

  # 2) Fallback: aplay -l (low confidence), locale-stable, no -P
  if [ "${#FOUND_MODELS[@]}" -eq 0 ] && [ -z "$OVERRIDE_CARD" ]; then
    log_plain "No codec in /proc/asound; aplay -l fallback"
    if [ "$VERBOSE" -eq 1 ]; then warn "No codec in /proc/asound; trying device-list fallback"; fi
    if command -v aplay &>/dev/null; then
      while IFS= read -r line; do
        local tok card
        tok=$(printf '%s' "$line" | grep -oE 'ALC[0-9]+[A-Za-z]*|RT[0-9]+[A-Za-z]*' | head -n1 || true)
        if [ -n "$tok" ]; then
          card=$(printf '%s' "$line" | sed -n 's/^card \([0-9][0-9]*\):.*/\1/p')
          if [ -n "$card" ]; then
            FOUND_CARDS+=("$card"); FOUND_CODECS+=("0")
            FOUND_MODELS+=("$(normalize_model "$tok")")
            FOUND_IFACES+=("$(chip_iface "$(normalize_model "$tok")")")
          fi
        fi
      done < <(LC_ALL=C aplay -l 2>/dev/null | grep -i "card " || true)
      if [ "${#FOUND_MODELS[@]}" -gt 0 ]; then FOUND_METHOD="aplay-l fallback (low confidence)"; fi
    fi
  fi

  # 3) USB audio hint (audio-class aware, not bare 0bda which false-positives on WiFi)
  # Sanitized: USB descriptors are external input, strip escape/control chars.
  if command -v lsusb &>/dev/null; then
    local usb_audio
    usb_audio=$(lsusb 2>/dev/null | grep -iE 'audio|headset|ALC40[0-9]{2}|0bda:.*(audio|4050|4040|4070|4080|4082)' | LC_ALL=C tr -d '\033\007\r' | head -c 300 || true)
    if [ -n "$usb_audio" ]; then USB_HINT="$usb_audio"; fi
    # Explicit ALC4080-class board VIDs (ASUS/MSI/Gigabyte rebrand the USB chip)
    if lsusb 2>/dev/null | grep -qE '0b05:(1996|1a20|1a27|1a5c)|0db0:(1feb|419c|a073|7696|82c7|005a|151f)|0414:a0'; then
      USB_HINT="${USB_HINT:+$USB_HINT; }Possible ALC4080/82 USB board ID detected"
    fi
  fi

  # 4) SOF / smart-amp hint
  if command -v lspci &>/dev/null; then
    if lspci -k 2>/dev/null | grep -qiE 'snd_sof|sof-audio|Smart Sound'; then
      SOF_HINT="SOF driver in use (lspci)"
    fi
  fi
  if dmesg 2>/dev/null | grep -qiE 'CSC3551|CS35L41|sof-audio|rt5682|rt715|rt1318|snd_sof'; then
    SOF_HINT="${SOF_HINT:+$SOF_HINT; }SOF/smart-amp marker in dmesg"
  fi
  if [ -n "$USB_HINT" ]; then
    log_plain "USB hint: $USB_HINT"
    if [ "$VERBOSE" -eq 1 ]; then warn "USB audio hint: $USB_HINT"; fi
  fi
  if [ -n "$SOF_HINT" ]; then
    warn "Extra sound hardware found (see log); the chip fix alone may not be enough."
    log_plain "SOF hint: $SOF_HINT"
    if [ "$VERBOSE" -eq 1 ]; then info "SOF detail: $SOF_HINT"; fi
  fi

  # 5) Explicit overrides
  if [ -n "$OVERRIDE_CHIP" ] || [ -n "$OVERRIDE_CARD" ]; then
    local m="${OVERRIDE_CHIP:-UNKNOWN}"
    m=$(normalize_model "$m")
    local c="${OVERRIDE_CARD:-0}"
    local ifc="UNKNOWN"
    if [ "$m" != "UNKNOWN" ] && [ "$m" != "UNKNOWN-MODEL" ]; then ifc=$(chip_iface "$m"); fi
    FOUND_CARDS=("$c"); FOUND_CODECS=("0"); FOUND_MODELS=("$m"); FOUND_IFACES=("$ifc")
    FOUND_METHOD="user override (--card/--chip)"
  fi

  if [ "${#FOUND_MODELS[@]}" -eq 0 ]; then
    JSON_STATUS="unsupported"
    err "No supported audio chip found."
    err "Checked the sound cards and the device list - nothing matches."
    info "If no sound card shows up at all, check that it is enabled in BIOS."
    info "Next: run with --list-chips to see what was found."
    info "USB sound (ALC4080 and similar) needs different settings, not this fix."
    return "$EXIT_NO_CHIP"
  fi

  if [ "${#FOUND_MODELS[@]}" -eq 1 ]; then
    ok "Audio chip: Realtek ${FOUND_MODELS[0]} (card ${FOUND_CARDS[0]})"
  else
    ok "Found ${#FOUND_MODELS[@]} audio chips"
  fi
  if [ "$VERBOSE" -eq 1 ]; then info "Detection: $FOUND_METHOD"; fi
  for i in "${!FOUND_MODELS[@]}"; do
    log_plain "  [$i] ${FOUND_MODELS[$i]} ${FOUND_IFACES[$i]} card=${FOUND_CARDS[$i]} codec=${FOUND_CODECS[$i]}"
    if [ "$VERBOSE" -eq 1 ]; then
      log "  [$i] ${FOUND_MODELS[$i]} (card ${FOUND_CARDS[$i]})"
    fi
  done
  if [ -n "$USB_HINT" ]; then
    warn "hda-verb only applies to HDA (PCI) codecs, NOT to USB audio. USB fix = UCM/PipeWire profile."
  fi
  return 0
}

list_chips() {
  if ! detect_chips; then exit "$EXIT_NO_CHIP"; fi
  if [ "$JSON" -eq 1 ]; then return 0; fi
  if [ "$QUIET" -eq 0 ]; then
    echo ""
    echo "Detected chips (no changes made):"
  fi
  printf '  %-4s %-8s %-7s %-4s %-5s %s\n' "ID" "MODEL" "IFACE" "CARD" "CODEC" "HINT"
  printf '  %-4s %-8s %-7s %-4s %-5s %s\n' "--" "-----" "-------" "----" "-----" "----"
  for i in "${!FOUND_MODELS[@]}"; do
    printf '  [%s]  %-8s %-5s %-4s %-5s %s\n' \
      "$i" "${FOUND_MODELS[$i]}" "${FOUND_IFACES[$i]}" "${FOUND_CARDS[$i]}" "${FOUND_CODECS[$i]}" \
      "$(chip_model_hint "${FOUND_MODELS[$i]}")"
  done
  if [ -n "$USB_HINT" ]; then echo "USB hint: $USB_HINT"; fi
  if [ -n "$SOF_HINT" ]; then echo "SOF hint: $SOF_HINT"; fi
}

choose_chip() {
  # One prompt when ambiguous (pure bash). --card N / --yes skips it.
  SELECTED_INDEX=0
  if [ "${#FOUND_MODELS[@]}" -gt 1 ] && [ -z "$OVERRIDE_CARD" ]; then
    log "Found ${#FOUND_MODELS[@]} sound cards:"
    for i in "${!FOUND_MODELS[@]}"; do
      log "  [$i] Realtek ${FOUND_MODELS[$i]} (card ${FOUND_CARDS[$i]})"
    done
    if can_prompt; then
      local sel=""
      ask "Which one to fix? Enter number [0] (or n to stop):" "0" sel
      case "$sel" in
        [Nn]|[Nn][Oo])
          info "Stopped. Nothing was changed."
          exit "$EXIT_ABORT"
          ;;
        *)
          if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -lt "${#FOUND_MODELS[@]}" ]; then
            SELECTED_INDEX="$sel"
          else
            warn "Not a valid number - using 0."
            SELECTED_INDEX=0
          fi
          log_plain "CHOICE: $SELECTED_INDEX"
          ;;
      esac
    else
      warn "Using [0] ${FOUND_MODELS[0]} (use --card N to pick)."
    fi
  fi
  MODEL="${FOUND_MODELS[$SELECTED_INDEX]}"
  CARD_NUM="${FOUND_CARDS[$SELECTED_INDEX]}"
  CODEC_NUM="${FOUND_CODECS[$SELECTED_INDEX]}"
  IFACE="${FOUND_IFACES[$SELECTED_INDEX]}"
  if [ "${#FOUND_MODELS[@]}" -eq 1 ] && [ -z "$OVERRIDE_CARD" ]; then
    : # already announced above; stay quiet
  else
    ok "Using: Realtek $MODEL (card $CARD_NUM)"
  fi
  log_plain "Tuning profile: $(chip_model_hint "$MODEL")"
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
BACKUP_STATE_FILE=""
default_backup_root() {
  # Stable home first, temp fallback last. Never /var/tmp by default.
  if [ -w /var/lib/audiofix 2>/dev/null ] || { [ "${EUID:-$(id -u)}" -eq 0 ] && mkdir -p /var/lib/audiofix 2>/dev/null; }; then
    printf '%s' "/var/lib/audiofix"
  elif [ -n "${HOME:-}" ] && [ -w "${HOME}" 2>/dev/null ]; then
    printf '%s' "${HOME}/.local/state/audiofix"
  else
    printf '%s' "/var/tmp"
  fi
}
backup_alsa() {
  local base="${BACKUP_DIR:-}"
  if [ -z "$base" ]; then
    BACKUP_ROOT="$(default_backup_root)"
    mkdir -p "$BACKUP_ROOT" 2>/dev/null || true
    base="$BACKUP_ROOT/audiofix-backup-$(date +%Y%m%d-%H%M%S)"
  fi
  local _home="${HOME:-}"
  local _canon
  _canon="$(canon_path "$base")"
  case "$_canon" in
    /var/lib/audiofix/*|/var/tmp/audiofix-backup-*|/tmp/audiofix-backup-*) ;;
    *)
      if [ -n "$_home" ]; then
        case "$_canon" in
          "$_home"/.local/state/audiofix/*) ;;
          *) die "Refusing backup outside /var/lib/audiofix, ~/.local/state/audiofix, or /var/tmp/audiofix-backup-* (got: $base)." "$EXIT_USAGE" ;;
        esac
      else
        die "Refusing backup outside /var/lib/audiofix or /var/tmp/audiofix-backup-* (got: $base)." "$EXIT_USAGE"
      fi
      ;;
  esac
  [ -L "$base" ] && die "Refusing backup through symlink: $base" "$EXIT_ENV"
  BACKUP_DIR="$base"
  if [ "$DRY_RUN" -eq 1 ]; then log "  (dry-run) would create backup dir: $BACKUP_DIR"; return 0; fi
  run mkdir -m 700 -p "$BACKUP_DIR" || { warn "Cannot create $BACKUP_DIR, aborting (backup required)"; return "$EXIT_ENV"; }
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  BACKUP_STATE_FILE="$BACKUP_DIR/asound.state.card${CARD_NUM}.bak"
  if command -v alsactl &>/dev/null; then
    if $SUDO alsactl store -f "$BACKUP_STATE_FILE" >>"$LOG_FILE" 2>&1; then
      chmod 600 "$BACKUP_STATE_FILE" 2>/dev/null || true
      ok "Backed up current settings"
      if [ "$VERBOSE" -eq 1 ]; then info "Backup: $BACKUP_STATE_FILE"; fi
      log_plain "Backup: $BACKUP_STATE_FILE"
    else warn "alsactl backup failed (live-USB/immutable /var?) continuing anyway"; fi
  fi
  if command -v amixer &>/dev/null; then
    amixer -c "$CARD_NUM" contents >"$BACKUP_DIR/amixer-contents.card${CARD_NUM}.txt" 2>>"$LOG_FILE" || true
    amixer -c "$CARD_NUM" controls >"$BACKUP_DIR/amixer-controls.card${CARD_NUM}.txt" 2>>"$LOG_FILE" || true
    chmod 600 "$BACKUP_DIR"/amixer-*.card*.txt 2>/dev/null || true
  fi
  if [ -f /etc/modprobe.d/alsa-fix.conf ]; then
    run cp -a /etc/modprobe.d/alsa-fix.conf "$BACKUP_DIR/" || true
  fi
}

# ---------------------------------------------------------------------------
# ALSA: disable Auto-Mute (ALL controls) + unmute essentials
# ---------------------------------------------------------------------------
fix_alsa() {
  step "Applying mixer fix"
  local controls
  controls=$(amixer -c "$CARD_NUM" controls 2>/dev/null | grep -i "Auto-Mute" || true)
  if [ -z "$controls" ]; then
    warn "No Auto-Mute control on card $CARD_NUM. Skipping Auto-Mute step."
  else
    local fixed=0 total=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local ctl
      ctl=$(printf '%s' "$line" | sed -n "s/.*name='\([^']*\)'.*/\1/p")
      [ -z "$ctl" ] && continue
      total=$((total+1))
      if [ "$VERBOSE" -eq 1 ]; then info "Found Auto-Mute control: '$ctl'"; fi
      # idempotency: skip if already Disabled/Off
      if amixer -c "$CARD_NUM" sget "$ctl" 2>/dev/null | grep -qiE 'Disabled|\[off\]'; then
        # sget shows values; Disabled enum appears literally, be conservative:
        if amixer -c "$CARD_NUM" sget "$ctl" 2>/dev/null | grep -q "Disabled"; then
          if [ "$VERBOSE" -eq 1 ]; then ok "'$ctl' already Disabled, skipping"; fi
          fixed=$((fixed+1)); continue
        fi
      fi
      local done_ctl=0
      for val in Disabled Off; do
        if run amixer -c "$CARD_NUM" sset "$ctl" "$val" >/dev/null 2>&1 || amixer -c "$CARD_NUM" sset "$ctl" "$val" >>"$LOG_FILE" 2>&1; then
          if [ "$DRY_RUN" -eq 1 ]; then fixed=$((fixed+1)); done_ctl=1; break; fi
          if amixer -c "$CARD_NUM" sget "$ctl" 2>/dev/null | grep -q "$val"; then
            fixed=$((fixed+1)); done_ctl=1; break
          fi
        fi
      done
      if [ "$done_ctl" -eq 0 ]; then warn "Could not disable '$ctl' (tried Disabled/Off)"; fi
    done <<< "$controls"
    AUTOMUTE_DONE=$fixed; AUTOMUTE_TOTAL=$total
    if [ "$fixed" -gt 0 ]; then
      if [ "$DRY_RUN" -eq 1 ]; then info "Preview: would turn off Auto-Mute"
      else ok "Auto-Mute turned off"; fi
    else info "Auto-Mute was already off"; fi
  fi

  local unmuted=()
  for ctl in Master Headphone Speaker PCM Front; do
    if amixer -c "$CARD_NUM" scontrols 2>/dev/null | grep -q "'$ctl'"; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log_plain "  (dry-run) would unmute: $ctl"
        unmuted+=("$ctl")
      else
        if amixer -c "$CARD_NUM" sset "$ctl" 80% unmute >>"$LOG_FILE" 2>&1; then
          unmuted+=("$ctl")
        else warn "Could not unmute $ctl"; fi
      fi
    fi
  done
  UNMUTED_LIST="${unmuted[*]:-none}"
  if [ "${#unmuted[@]}" -gt 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then info "Preview: would unmute ${unmuted[*]} and set volume to 80%"
    else ok "Unmuted ${unmuted[*]} (volume 80%)"; fi
  fi
  if [ "$DRY_RUN" -eq 1 ]; then log "  (dry-run) would run: ${SUDO:-sudo} alsactl store"
  else
    if [ -z "${BACKUP_STATE_FILE:-}" ] || [ ! -s "$BACKUP_STATE_FILE" ]; then
      warn "No verified backup ($BACKUP_STATE_FILE); skipping 'alsactl store' to avoid persisting a bad state"
    elif $SUDO alsactl store >>"$LOG_FILE" 2>&1; then ok "ALSA state saved (alsactl store)"
    else warn "'alsactl store' failed; change may not survive reboot (live-USB/immutable?)" ; fi
  fi
}

# ---------------------------------------------------------------------------
# hda-verb (HDA only, device-node verified, GET-probed)
# ---------------------------------------------------------------------------
resolve_hda_dev() {
  local exact="/dev/snd/hwC${CARD_NUM}D${CODEC_NUM}"
  if [ -e "$exact" ]; then echo "$exact"; return 0; fi
  # codec# != D index on SOF/HDA splits: pick first node for this card, verify with GET
  local cand
  for cand in /dev/snd/hwC"${CARD_NUM}"D*; do
    [ -e "$cand" ] || continue
    echo "$cand"
    return 0
  done
  return 1
}

fix_hda_verbs() {
  step "Sending chip commands"
  if [ "$IFACE" = "USB" ]; then
    warn "$MODEL is USB sound, so chip commands do not apply."
    log_plain "USB path: usbmixer cat + ucm2 grep + VID:PID profile (card $CARD_NUM)"
    if [ "$VERBOSE" -eq 1 ]; then
      info "USB path: check the mixer, PipeWire profile, and USB sound settings:"
      info "  cat /proc/asound/card${CARD_NUM}/usbmixer 2>/dev/null | head -20"
      info "  grep -R ALC4080 /usr/share/alsa/ucm2/USB-Audio/ 2>/dev/null | head"
      info "  Your board USB ID must be in USB-Audio.conf profile; else append VID:PID and restart pipewire."
    fi
    if [ "$FORCE" -eq 0 ]; then warn "Skipping hda-verb (use --force to override, not recommended)"; return 0; fi
  fi
  if [ "$IFACE" = "SOF" ]; then
    warn "$MODEL needs firmware sound drivers, so chip commands do not apply."
    log_plain "SOF path: sof-firmware/topology + dsp_driver option"
    if [ "$VERBOSE" -eq 1 ]; then
      info "SOF path: install sof-firmware/SOF topology, try:"
      info "  options snd-intel-dspcfg dsp_driver=1  (or =3) in /etc/modprobe.d, then reboot"
    fi
    if [ "$FORCE" -eq 0 ]; then warn "Skipping hda-verb (use --force to override)"; return 0; fi
  fi
  if [ "$MODEL" = "UNKNOWN-MODEL" ] || [ "$MODEL" = "UNKNOWN" ] || [ "$IFACE" = "UNKNOWN" ]; then
    warn "Your chip is not in the known list, so the standard commands may be wrong for it."
    if [ "$FORCE" -eq 0 ]; then
      JSON_STATUS="unsupported"
      die "Stopped for safety: this chip is not in the known list, so the standard commands may be wrong for it. A backup was saved first. Re-run with --chip ALCxxx --force to try anyway." "$EXIT_HW"
    fi
    if can_prompt; then
      if ! confirm_yn "Apply the standard commands anyway? [y/N]:" "N"; then
        info "Stopped. Nothing was changed."
        exit "$EXIT_ABORT"
      fi
    else
      warn "--force given without a terminal; proceeding on unknown chip"
    fi
  fi
  if [ "$APPLY_VERBS_ONLY" -eq 0 ] && [ -n "$SOF_HINT" ]; then
    warn "Smart-amp/SOF marker present: $SOF_HINT"
    warn "hda-verb alone may not fix speakers (needs CS35L41/amp quirk + kernel >=6.x). Continuing with verbs anyway."
  fi

  local hda_dev
  if ! hda_dev=$(resolve_hda_dev); then
    JSON_STATUS="unsupported"
    die "No sound device found for card $CARD_NUM. The audio driver may not be loaded yet. Try restarting, then run with --verbose and share the log." "$EXIT_HW"
  fi
  if [ "$hda_dev" != "/dev/snd/hwC${CARD_NUM}D${CODEC_NUM}" ]; then
    log_plain "Exact node hwC${CARD_NUM}D${CODEC_NUM} missing; using $hda_dev"
    if [ "$VERBOSE" -eq 1 ]; then warn "Sound device path changed, using fallback."; fi
  fi
  info "Sending the $MODEL startup commands to the chip..."
  log_plain "Target: $hda_dev ($MODEL)"
  VERBS_OK=0; VERBS_TOTAL=${#GENERIC_VERBS[@]}

  # GET probe: verify HDA communication before SET verbs
  if [ "$DRY_RUN" -eq 0 ]; then
    if ! run_spin "Probing HDA codec..." $SUDO hda-verb "$hda_dev" 0x20 0xF00 0x00; then
      warn "hda-verb GET probe failed on $hda_dev; SET verbs may also fail"
    elif [ "$VERBOSE" -eq 1 ]; then ok "hda-verb GET probe OK on $hda_dev"; fi
  fi

  local ok_count=0 fail_count=0 cmd
  for cmd in "${GENERIC_VERBS[@]}"; do
    # shellcheck disable=SC2086
    if run $SUDO hda-verb "$hda_dev" $cmd; then ok_count=$((ok_count+1))
    else warn "One chip command failed (details in the log)"; fail_count=$((fail_count+1)); fi
  done
  VERBS_OK=$ok_count
  # Persist verb list for the systemd replay unit (under private backup dir, not /tmp)
  if [ "$DRY_RUN" -eq 0 ] && [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR" ]; then
    printf '%s\n' "${GENERIC_VERBS[@]}" >"$BACKUP_DIR/audiofix-verbs.card${CARD_NUM}.conf" 2>/dev/null || true
    chmod 600 "$BACKUP_DIR"/audiofix-verbs.card*.conf 2>/dev/null || true
  fi
  if [ "$fail_count" -eq 0 ]; then
    if [ "$VERBOSE" -eq 1 ]; then ok "All $ok_count hda-verb command(s) succeeded on $hda_dev"; fi
  else
    warn "$fail_count verb(s) failed (see $LOG_FILE)"
    if [ "$APPLY_VERBS_ONLY" -eq 1 ]; then return "$EXIT_ENV"; fi
  fi
  # Record for persistence step
  HDA_DEV_USED="$hda_dev"
}

# ---------------------------------------------------------------------------
# Persistence: modprobe quirk + systemd replay (verbs are volatile)
# ---------------------------------------------------------------------------
persist_fix() {
  step "Making it permanent"
  if [ "$PERSIST" = "no" ]; then info "Skipped (--no-persist)"; return 0; fi
  # Decided upfront in main (wizard Q2). Never asks here.
  if [ "$PERSIST" = "prompt" ]; then PERSIST="yes"; fi
  if [ "$IFACE" = "USB" ] || [ "$IFACE" = "SOF" ]; then
    warn "Permanent setup for $IFACE sound works differently - skipping."
    log_plain "USB: VID:PID ucm2 profile; SOF: dsp_driver option"
    return 0
  fi
  if [[ "$PERSIST_MODE" == "modprobe" || "$PERSIST_MODE" == "both" ]]; then
    local conf="/etc/modprobe.d/alsa-fix.conf"
    local hint
    hint=$(chip_model_hint "$MODEL")
    local first_model
    first_model=$(printf '%s' "$hint" | cut -d, -f1 | LC_ALL=C tr -d ' ')
    info "Persistence: on (survives reboot)"
    if [ "$VERBOSE" -eq 1 ]; then info "Writing $conf (model=$first_model for $MODEL)"; fi
    local content="# Generated by AudioFix v${VERSION} on $(date -u +%FT%TZ) for $MODEL card $CARD_NUM
# Alternatives for this chip: model=$hint
# Docs: https://docs.kernel.org/sound/hd-audio/models.html
options snd-hda-intel model=${first_model}
options snd-intel-dspcfg dsp_driver=1
"
    if [ "$DRY_RUN" -eq 1 ]; then log "  (dry-run) would write $conf + rebuild initramfs"
    else
      if echo "$content" | $SUDO tee "$conf" >>"$LOG_FILE" 2>&1; then
        if [ "$VERBOSE" -eq 1 ]; then ok "Wrote $conf"; fi
      else warn "Could not write $conf"; fi
      # rebuild initramfs (best effort, distro aware; can take a minute - spinner)
      if command -v update-initramfs &>/dev/null; then run_spin "Rebuilding initramfs (update-initramfs, may take a minute)..." $SUDO update-initramfs -u || true
      elif command -v dracut &>/dev/null; then run_spin "Rebuilding initramfs (dracut, may take a minute)..." $SUDO dracut -f || true
      elif command -v mkinitcpio &>/dev/null; then run_spin "Rebuilding initramfs (mkinitcpio, may take a minute)..." $SUDO mkinitcpio -P || true
      fi
    fi
  fi
  if [[ "$PERSIST_MODE" == "systemd" || "$PERSIST_MODE" == "both" ]]; then
    local dev="${HDA_DEV_USED:-/dev/snd/hwC${CARD_NUM}D${CODEC_NUM}}"
    case "$dev" in
      /dev/snd/hwC[0-9]*D[0-9]*) ;;
      *) die "Refusing to install unit for unexpected device path: $dev" "$EXIT_ENV" ;;
    esac
    local esc_dev
    esc_dev=$(printf '%s' "$dev" | LC_ALL=C tr -d '"$`!\\' || printf '%s' "$dev")
    info "Installing systemd verb-replay for $dev"
    local helper="/usr/local/bin/audiofix-verbs.sh"
    local unit="/etc/systemd/system/audiofix-hdaverb.service"
    local helper_content="#!/usr/bin/env bash
# Generated by AudioFix v${VERSION} - replays EAPD/coef verbs after boot/resume
set -u
DEV=\"${esc_dev}\"
[ -e \"\$DEV\" ] || exit 0
command -v hda-verb >/dev/null || exit 0
hda-verb \"\$DEV\" 0x20 0x500 0x1b >/dev/null 2>&1 || true
hda-verb \"\$DEV\" 0x20 0x477 0x4a4b >/dev/null 2>&1 || true
hda-verb \"\$DEV\" 0x20 0x500 0xf >/dev/null 2>&1 || true
hda-verb \"\$DEV\" 0x20 0x477 0x74 >/dev/null 2>&1 || true
"
    local unit_content="[Unit]
Description=AudioFix hda-verb replay for ${MODEL} (${dev})
After=sound.target
ConditionPathExists=${dev}

[Service]
Type=oneshot
ExecStart=${helper}

[Install]
WantedBy=multi-user.target
"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "  (dry-run) would write $helper and $unit + systemctl enable"
    else
      if [ -L "$helper" ] || [ -L "$unit" ]; then
        warn "Refusing to overwrite symlink: $helper / $unit"; return 0
      fi
      if echo "$helper_content" | $SUDO tee "$helper" >>"$LOG_FILE" 2>&1 \
        && $SUDO chmod +x "$helper" >>"$LOG_FILE" 2>&1 \
        && echo "$unit_content" | $SUDO tee "$unit" >>"$LOG_FILE" 2>&1; then
        ok "Installed $unit"
        if command -v systemctl &>/dev/null; then
          run $SUDO systemctl daemon-reload || true
          run $SUDO systemctl enable audiofix-hdaverb.service || warn "systemctl enable failed"
        else warn "systemctl not found (OpenRC/runit?); enable replay manually"; fi
      else warn "Could not install systemd unit"; fi
    fi
  fi
  stop_keepalive
}

# ---------------------------------------------------------------------------
# Verify + uninstall + reboot
# ---------------------------------------------------------------------------
verify_fix() {
  # Calm: details to log (and screen in --verbose), one result line otherwise.
  log_plain "verify: card=$CARD_NUM model=$MODEL"
  if command -v amixer &>/dev/null; then
    local automute_state
    automute_state=$(amixer -c "$CARD_NUM" sget "Auto-Mute Mode" 2>/dev/null || amixer -c "$CARD_NUM" contents 2>/dev/null | grep -i -A1 "Auto-Mute" | head -5 || true)
    log_plain "amixer: $automute_state"
    if printf '%s' "$automute_state" | grep -q "Disabled"; then
      if [ "$VERBOSE" -eq 1 ]; then ok "Auto-Mute reads Disabled"; fi
    else
      warn "Auto-Mute still looks enabled. The fix may not hold - details in the log."
    fi
  fi
  if command -v aplay &>/dev/null; then LC_ALL=C aplay -l 2>/dev/null | head -10 >>"$LOG_FILE" 2>/dev/null || true; fi
  dmesg 2>/dev/null | grep -iE 'snd|hda|sof|ALC|CSC3551' | tail -5 >>"$LOG_FILE" 2>/dev/null || true
}
test_sound() {
  # Offers the test tone, asks if it was heard. Sets HEARD=Y/N/skip.
  HEARD="skip"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "  (dry-run) would offer a test sound"
    return 0
  fi
  if ! can_prompt; then return 0; fi
  if ! confirm_yn "Play a test sound? [Y/n]:" "Y"; then
    info "Test skipped. Play any audio yourself to confirm."
    return 0
  fi
  info "Playing a test sound..."
  log_plain "speaker-test start"
  if command -v timeout &>/dev/null; then
    timeout 8 speaker-test -c2 -t wav -D "hw:${CARD_NUM}" -l1 >>"$LOG_FILE" 2>&1
  else
    speaker-test -c2 -t wav -D "hw:${CARD_NUM}" -l1 >>"$LOG_FILE" 2>&1
  fi
  local code=$?
  log_plain "speaker-test exit=$code"
  if [ "$code" -ne 0 ]; then
    warn "The test sound itself failed to play (see log). Check the output device first."
  fi
  if confirm_yn "Did you hear it? [y/N]:" "N"; then HEARD="Y"; else HEARD="N"; fi
}
test_failed_next_steps() {
  warn "No sound heard. Things to try:"
  log "  1. Check the output device:  wpctl status"
  log "  2. Or open the volume panel:  pavucontrol"
  log "  3. Re-run with details:       $0 --verbose"
  log "  4. Share this log for help:   $LOG_FILE"
  log_plain "next: wpctl status / pavucontrol / --verbose / log"
}

do_uninstall() {
  step "Removing permanent fix"
  if [ "$DRY_RUN" -eq 1 ]; then log "  (dry-run) would remove /etc/modprobe.d/alsa-fix.conf + audiofix-hdaverb.service"; return 0; fi
  if [ -f /etc/modprobe.d/alsa-fix.conf ] && [ ! -L /etc/modprobe.d/alsa-fix.conf ]; then run $SUDO rm -f /etc/modprobe.d/alsa-fix.conf && ok "Removed /etc/modprobe.d/alsa-fix.conf"
  elif [ -L /etc/modprobe.d/alsa-fix.conf ]; then warn "Refusing to remove symlink /etc/modprobe.d/alsa-fix.conf"
  else info "No /etc/modprobe.d/alsa-fix.conf found"; fi
  if [ -f /etc/systemd/system/audiofix-hdaverb.service ]; then
    if [ -L /etc/systemd/system/audiofix-hdaverb.service ]; then warn "Refusing to remove symlink unit"
    else
      if command -v systemctl &>/dev/null; then run $SUDO systemctl disable audiofix-hdaverb.service || true; fi
      run $SUDO rm -f /etc/systemd/system/audiofix-hdaverb.service && ok "Removed audiofix-hdaverb.service"
      if command -v systemctl &>/dev/null; then run $SUDO systemctl daemon-reload || true; fi
    fi
  else info "No audiofix-hdaverb.service found"; fi
  if [ -f /usr/local/bin/audiofix-verbs.sh ] && [ ! -L /usr/local/bin/audiofix-verbs.sh ]; then run $SUDO rm -f /usr/local/bin/audiofix-verbs.sh && ok "Removed helper"; fi
  if [ -n "$BACKUP_STATE_FILE" ] && [ -f "$BACKUP_STATE_FILE" ]; then
    if backup_allowed_path "$BACKUP_STATE_FILE"; then
      if $SUDO alsactl restore -f "$BACKUP_STATE_FILE" >>"$LOG_FILE" 2>&1; then ok "Restored $BACKUP_STATE_FILE"; fi
    else warn "Refusing to restore from unexpected path: $BACKUP_STATE_FILE"; fi
  else
    local latest=""
    latest=$(find_latest_backup)
    if [ -n "$latest" ]; then
      if backup_allowed_path "$latest"; then
        info "Found backup $latest"
        if $SUDO alsactl restore -f "$latest" >>"$LOG_FILE" 2>&1; then ok "Restored $latest"; else warn "Restore failed"; fi
      else warn "Refusing to restore from unexpected path"; fi
    else info "No ALSA backup found to restore"; fi
  fi
}

find_latest_backup() {
  # Prints newest saved settings file under known backup folders, or nothing.
  local roots=()
  [ -d /var/lib/audiofix ] && roots+=(/var/lib/audiofix)
  if [ -n "${HOME:-}" ] && [ -d "${HOME}/.local/state/audiofix" ]; then
    roots+=("${HOME}/.local/state/audiofix")
  fi
  roots+=(/var/tmp /tmp)
  find "${roots[@]}" -maxdepth 2 -name 'asound.state.*' -print 2>/dev/null | head -n1 || true
}
backup_allowed_path() {
  # Returns 0 if $1 lives inside a known backup folder (canonicalized).
  local _c
  _c="$(canon_path "$1")"
  case "$_c" in
    /var/lib/audiofix/*|/var/tmp/audiofix-backup-*|/tmp/audiofix-backup-*) return 0 ;;
  esac
  if [ -n "${HOME:-}" ]; then
    case "$_c" in "${HOME}"/.local/state/audiofix/*) return 0 ;; esac
  fi
  return 1
}
do_restore() {
  section "Undo"
  local src="${RESTORE_DIR:-}"
  if [ -z "$src" ]; then
    src="$(find_latest_backup)"
  else
    [ -d "$src" ] || die "Backup folder not found: $src. Check the path with --help." "$EXIT_USAGE"
    src="$(find "$src" -maxdepth 1 -name 'asound.state.*' -print 2>/dev/null | head -n1 || true)"
  fi
  [ -n "$src" ] || die "No saved settings found to put back. Run a fix first to create a backup, or check --backup-dir." "$EXIT_ENV"
  backup_allowed_path "$src" || die "Refusing to restore from an unexpected place. Backups live under /var/lib/audiofix or ~/.local/state/audiofix." "$EXIT_ENV"
  [ -L "$src" ] && die "Refusing to restore through a symlink: $src" "$EXIT_ENV"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would put back: $src (nothing changed)"
    return 0
  fi
  if $SUDO alsactl restore -f "$src" >>"$LOG_FILE" 2>&1; then
    ok "Settings put back from backup."
    JSON_STATUS="ok"
  else
    die "Restore failed. See the log: $LOG_FILE" "$EXIT_ENV"
  fi
}

show_plan() {
  if [ "$DRY_RUN" -eq 1 ]; then section "What would change"; else section "What will change"; fi
  log "  ${M_BULLET} Unmute ${UNMUTED_PREVIEW:-Master, Speaker and PCM}, and set volume to 80%"
  log "  ${M_BULLET} Turn off Auto-Mute (speakers stay on when headphones are plugged in)"
  log "  ${M_BULLET} Send the $MODEL startup commands to the chip (${#GENERIC_VERBS[@]} commands)"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "  A backup would be saved first. Nothing changes until you confirm."
  else
    log "  A backup is saved first. Nothing changes until you confirm."
  fi
  log_plain "Plan: unmute + Auto-Mute off + chip init (${#GENERIC_VERBS[@]} verbs)"
}
preview_unmute() {
  # Names the mixer controls that actually exist, for the plan screen.
  UNMUTED_PREVIEW=""
  if ! command -v amixer &>/dev/null; then return 0; fi
  local found=()
  local ctl
  for ctl in Master Headphone Speaker PCM Front; do
    if amixer -c "$CARD_NUM" scontrols 2>/dev/null | grep -q "'$ctl'"; then
      found+=("$ctl")
    fi
  done
  if [ "${#found[@]}" -gt 0 ]; then UNMUTED_PREVIEW="${found[*]}"; fi
}
handle_reboot() {
  if [ "$NO_REBOOT" -eq 1 ]; then
    if [ "$PERSIST" = "no" ]; then
      warn "Do not restart: it would undo this temporary fix."
    else
      info "Restart on your own when ready: sudo reboot"
    fi
    return 0
  fi
  # Asked upfront in main (only when a restart is needed). Never asks here.
  if [ "$DO_REBOOT" -eq 1 ] || [ "${WANT_REBOOT:-N}" = "Y" ]; then
    ok "Restarting in 5s (Ctrl+C to cancel)..."
    sleep 5
    cleanup
    if command -v systemctl &>/dev/null; then $SUDO systemctl reboot || $SUDO reboot
    else $SUDO reboot; fi
    return 0
  fi
  if [ "$PERSIST" = "no" ]; then
    warn "Do not restart: it would undo this temporary fix."
  else
    info "Restart on your own when ready: sudo reboot"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  init_colors
  init_log
  trap cleanup EXIT
  trap 'JSON_DETAIL="Stopped while running: $BASH_COMMAND. Check the log for details."; cleanup; trap - EXIT INT TERM HUP; err "Stopped while running: $BASH_COMMAND. Check the log for details."; exit $EXIT_ENV' ERR
  trap on_interrupt INT TERM HUP
  if [ "$DRY_RUN" -eq 0 ] && [ "$LIST_CHIPS_ONLY" -eq 0 ]; then
    acquire_lock
  fi

  if [ "$QUIET" -eq 0 ]; then echo ""; fi
  banner

  if [ "$RESTORE" -eq 1 ]; then
    init_sudo
    do_restore
    JSON_STATUS="ok"
    exit "$?"
  fi

  if [ "$UNINSTALL" -eq 1 ]; then
    init_sudo
    do_uninstall
    JSON_STATUS="ok"
    handle_reboot
    exit "$EXIT_OK"
  fi

  if [ "$LIST_CHIPS_ONLY" -eq 1 ]; then
    list_chips
    JSON_STATUS="ok"
    exit "$EXIT_OK"
  fi

  if [ "$APPLY_VERBS_ONLY" -eq 1 ]; then
    # minimal path for systemd unit (no prompts, no persist loop)
    init_sudo
    detect_chips || exit "$EXIT_NO_CHIP"
    choose_chip
    fix_hda_verbs || exit "$?"
    exit "$?"
  fi

  init_sudo
  section "Checking your system"
  ensure_deps
  detect_chips || exit "$EXIT_NO_CHIP"
  choose_chip
  info "System: $OS_PRETTY"
  info "Sound server: $SOUND_SERVER"
  log_plain "System: $OS_PRETTY / $SOUND_SERVER"
  preview_unmute

  if [ "$DRY_RUN" -eq 1 ]; then info "Preview only - nothing will change"; fi

  show_plan
  if can_prompt; then
    if ! confirm_yn "Apply the fix now? [Y/n]:" "Y"; then
      info "Stopped. Nothing was changed."
      JSON_STATUS="aborted"
      exit "$EXIT_ABORT"
    fi
    if [ "$PERSIST" = "prompt" ]; then
      if confirm_yn "Keep it after restart? (recommended) [Y/n]:" "Y"; then PERSIST="yes"; else PERSIST="no"; fi
    fi
  else
    if [ "$PERSIST" = "prompt" ]; then PERSIST="yes"; fi
  fi
  if [ "$DO_REBOOT" -eq 1 ]; then WANT_REBOOT="Y"; else WANT_REBOOT="N"; fi

  section "Applying"
  backup_alsa
  info "Undo anytime with: $0 --restore"
  log_plain "Undo: $0 --restore"
  fix_alsa
  fix_hda_verbs || exit "$?"
  if [ "$PERSIST" != "no" ]; then persist_fix; else warn "Temporary fix: a restart will undo it."; fi
  verify_fix

  section "Testing"
  test_sound

  if [ "$HEARD" = "N" ]; then
    JSON_STATUS="verify_failed"
    test_failed_next_steps
    log "  Log: $LOG_FILE"
    log_plain "Log: $LOG_FILE"
    exit "$EXIT_VERIFY"
  fi

  section "Done"
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$PERSIST" = "no" ]; then JSON_STATUS="temporary"; else JSON_STATUS="ok"; fi
    log "  Nothing was changed."
    log "  Log:       $LOG_FILE"
    log_plain "Dry run complete, nothing changed"
    return 0
  fi
  if [ "$PERSIST" = "no" ]; then
    JSON_STATUS="temporary"
    warn "Done, but this fix is temporary and will be lost on restart."
    log "  Run again without --no-persist to make it permanent."
    log "  Undo it:   $0 --restore"
    log "  Log:       $LOG_FILE"
  else
    JSON_STATUS="ok"
    ok "Done. Your audio fix is active and will survive a restart."
    log "  Undo it:   $0 --restore"
    log "  Log:       $LOG_FILE"
  fi
  log_plain "Done: model=$MODEL card=$CARD_NUM verbs=$VERBS_OK/$VERBS_TOTAL persist=$PERSIST heard=$HEARD"
  if [ "$IFACE" != "HDA" ]; then warn "$MODEL is $IFACE - see USB/SOF guidance above."; fi
  if [ -n "$SOF_HINT" ]; then warn "SOF/amp hint - check sof-firmware + CS35L41 quirk."; fi

  # A restart is only needed to load the permanent settings.
  if [ "$PERSIST" != "no" ] && [ "$NO_REBOOT" -eq 0 ] && [ "$DO_REBOOT" -eq 0 ]; then
    if can_prompt; then
      if confirm_yn "Restart now? [y/N]:" "N"; then WANT_REBOOT="Y"; fi
    fi
  fi

  handle_reboot
}

main "$@"
