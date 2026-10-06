#!/usr/bin/env bash
#
# AudioFix.sh v2.0.0 - Prod-grade Realtek HDA audio fix
#
# Fixes: Auto-Mute muting speakers/headphones + missing EAPD/coef init (hda-verb)
# Repo: https://github.com/hello2himel/linux-audio-fix
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/hello2himel/linux-audio-fix/main/AudioFix.sh | bash -s -- [options]
#   ./AudioFix.sh [options]
#
# Examples:
#   ./AudioFix.sh --list-chips            # probe only, change nothing
#   ./AudioFix.sh --dry-run --verbose     # preview what would happen
#   ./AudioFix.sh                         # interactive fix (recommended)
#   ./AudioFix.sh --yes --reboot          # unattended + reboot
#   ./AudioFix.sh --card 1 --chip ALC256 --force  # override detection
#   ./AudioFix.sh --uninstall             # remove persistence, restore backup
#
set -Eeuo pipefail
# Secure PATH for root execs (pentest: PATH hijack via update-initramfs etc.)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

VERSION="2.0.0"

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
APPLY_VERBS_ONLY=0
OVERRIDE_CARD=""
OVERRIDE_CHIP=""
PERSIST="prompt"          # prompt|yes|no
PERSIST_MODE="both"       # modprobe|systemd|both
BACKUP_DIR=""
LOG_FILE_OVERRIDE=""
SUDO_KEEPALIVE_PID=""
MODEL=""; CARD_NUM=""; CODEC_NUM=""; IFACE=""; SELECTED_INDEX=0
HDA_DEV_USED=""
VERBS_OK=0; VERBS_TOTAL=4
AUTOMUTE_DONE=0; AUTOMUTE_TOTAL=0
WANT_REBOOT="N"

EXIT_OK=0
EXIT_ENV=1
EXIT_NO_CHIP=2
EXIT_PKG=3
EXIT_VERB=4

# ---------------------------------------------------------------------------
# Help / version
# ---------------------------------------------------------------------------
print_help() {
  cat <<EOF
AudioFix v${VERSION} - Realtek HDA audio fix (Auto-Mute + hda-verb EAPD init)

Usage: $0 [options]

Detection:
  --list-chips          List detected codecs and exit (no changes)
  --card N              Force use of ALSA card N (skip chooser)
  --chip MODEL          Force chip model, e.g. --chip ALC256 (use with --force if unknown)
  --force               Allow running on unknown / non-allowlisted / USB+SOF chips

Run modes:
  -n, --dry-run         Preview only, change nothing (implies --no-reboot, no prompts)
  -y, --yes             Skip questions, use defaults (no reboot unless --reboot)
  --reboot              Reboot automatically at end (default: ask once, default N)
  --no-reboot           Never reboot, never ask
  --apply-verbs-only    Internal: replay hda-verbs only (used by systemd unit)

  Interactive: 3 questions max (chip if ambiguous, persist, reboot).
  Non-TTY, --yes, or --dry-run: uses defaults, never waits.

Persistence:
  --persist             Install boot persistence (modprobe + systemd verb replay)
  --no-persist          Skip boot persistence
  --persist-mode MODE   modprobe|systemd|both (default: both)

Maintenance:
  --backup-dir DIR      Where to store backups (default: auto under /var/tmp or /tmp)
  --uninstall           Remove persistence files + restore ALSA backup if found
  -v, --verbose         Verbose command output
  -q, --quiet           Minimal output (warnings/errors only)
  --no-color            Disable colors (also honors NO_COLOR env)
  --plain, --no-tui     Accepted, ignored (prompts are already plain bash)
  --log-file PATH       Custom log path
  -h, --help            Show this help
  --version             Show version

Exit codes: 0 ok | 1 env/usage | 2 no chip | 3 package fail | 4 verb fail

Supported chips (HDA, hda-verb safe): ALC221 ALC231 ALC233 ALC234 ALC235 ALC236
  ALC245 ALC255 ALC256/ALC3246 ALC257 ALC259 ALC260 ALC262 ALC267 ALC268 ALC269
  ALC270 ALC271X ALC272 ALC273 ALC274/ALC3254 ALC275 ALC276 ALC280 ALC282 ALC283
  ALC284 ALC285 ALC286 ALC287 ALC288 ALC289 ALC290 ALC292/ALC3220 ALC293 ALC294
  ALC295/ALC3253 ALC298 ALC299 ALC300 ALC215 ALC225 ALC230 ALC3234 ALC668 ALC670
  ALC671 ALC672 ALC676 ALC680 ALC662 ALC663 ALC665 ALC891 ALC861 ALC861VD ALC867
  ALC880 ALC882 ALC883 ALC885 ALC887 ALC888 ALC889 ALC892 ALC898 ALC899 ALC1150
  ALC1220/ALC1220P/ALC1220-VB/ALCS1220A ALC1250 ALC897 ALC1200 ALC700
USB (hda-verb does NOT apply, script guides UCM instead): ALC4080 ALC4082
  ALC4040 ALC4050 ALC4070
SOF/I2S/SoundWire (hda-verb does NOT apply): RT5682/S RT715 RT714 RT1318/ALC1318
  RT1320 RT722 ALC3306-as-ALC287 (hybrid, needs amp quirk)

Notes:
  - hda-verb is volatile: it is lost on reboot/suspend. Use --persist for a
    systemd replay unit + modprobe model quirk.
  - USB and SOF devices are detected and explained, not blindly verb-poked.
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
      --plain|--no-tui) PLAIN=1; shift ;;
      --force) FORCE=1; shift ;;
      --list-chips|--list) LIST_CHIPS_ONLY=1; shift ;;
      --uninstall) UNINSTALL=1; shift ;;
      --apply-verbs-only) APPLY_VERBS_ONLY=1; shift ;;
      --persist) PERSIST="yes"; shift ;;
      --no-persist) PERSIST="no"; shift ;;
      --persist-mode)
        [ $# -ge 2 ] || { echo "ERROR: --persist-mode needs a value (modprobe|systemd|both)" >&2; exit "$EXIT_ENV"; }
        PERSIST_MODE="$2"; shift 2 ;;
      --persist-mode=*)
        [ -n "${1#*=}" ] || { echo "ERROR: --persist-mode= needs a value" >&2; exit "$EXIT_ENV"; }
        PERSIST_MODE="${1#*=}"; shift ;;
      --card)
        [ $# -ge 2 ] || { echo "ERROR: --card needs a number" >&2; exit "$EXIT_ENV"; }
        OVERRIDE_CARD="$2"; shift 2 ;;
      --card=*)
        [ -n "${1#*=}" ] || { echo "ERROR: --card= needs a number" >&2; exit "$EXIT_ENV"; }
        OVERRIDE_CARD="${1#*=}"; shift ;;
      --chip)
        [ $# -ge 2 ] || { echo "ERROR: --chip needs a value (e.g. ALC256)" >&2; exit "$EXIT_ENV"; }
        OVERRIDE_CHIP="$2"; shift 2 ;;
      --chip=*)
        [ -n "${1#*=}" ] || { echo "ERROR: --chip= needs a value" >&2; exit "$EXIT_ENV"; }
        OVERRIDE_CHIP="${1#*=}"; shift ;;
      --backup-dir)
        [ $# -ge 2 ] || { echo "ERROR: --backup-dir needs a directory" >&2; exit "$EXIT_ENV"; }
        BACKUP_DIR="$2"; shift 2 ;;
      --backup-dir=*)
        [ -n "${1#*=}" ] || { echo "ERROR: --backup-dir= needs a directory" >&2; exit "$EXIT_ENV"; }
        BACKUP_DIR="${1#*=}"; shift ;;
      --log-file)
        [ $# -ge 2 ] || { echo "ERROR: --log-file needs a path" >&2; exit "$EXIT_ENV"; }
        LOG_FILE_OVERRIDE="$2"; shift 2 ;;
      --log-file=*)
        [ -n "${1#*=}" ] || { echo "ERROR: --log-file= needs a path" >&2; exit "$EXIT_ENV"; }
        LOG_FILE_OVERRIDE="${1#*=}"; shift ;;
      --) shift; break ;;
      -*) echo "ERROR: unknown option: $1 (see --help)" >&2; exit "$EXIT_ENV" ;;
      *) echo "ERROR: unexpected argument: $1 (see --help)" >&2; exit "$EXIT_ENV" ;;
    esac
  done
  if [ $# -gt 0 ]; then
    echo "ERROR: unexpected argument: $1 (see --help)" >&2; exit "$EXIT_ENV"
  fi

  case "$PERSIST_MODE" in
    modprobe|systemd|both) ;;
    *) echo "ERROR: --persist-mode must be modprobe|systemd|both" >&2; exit "$EXIT_ENV" ;;
  esac
  if [ -n "$OVERRIDE_CARD" ] && ! [[ "$OVERRIDE_CARD" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --card must be a number, got: $OVERRIDE_CARD" >&2
    exit "$EXIT_ENV"
  fi
}

# ---------------------------------------------------------------------------
# Colors / logging (NO_COLOR + TTY aware, no emoji in file log)
# ---------------------------------------------------------------------------
USE_COLOR=0
C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""; C_WHITE=""
init_colors() {
  if [ "$NO_COLOR_FLAG" -eq 1 ]; then return 0; fi
  if [ -n "${NO_COLOR:-}" ]; then return 0; fi
  # TERM=dumb or no TTY -> no colors, still print ASCII art
  if [ "${TERM:-}" = "dumb" ]; then return 0; fi
  if [ -t 1 ] && command -v tput &>/dev/null; then
    if tput colors &>/dev/null && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
      USE_COLOR=1
      C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
      C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
      C_BLUE=$'\e[34m'; C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'; C_WHITE=$'\e[37m'
    fi
  fi
}

LOG_FILE=""
init_log() {
  if [ -n "$LOG_FILE_OVERRIDE" ]; then
    case "$LOG_FILE_OVERRIDE" in
      /tmp/*|/var/tmp/*|/var/log/*) ;;
      *) echo "ERROR: --log-file must be under /tmp, /var/tmp, or /var/log (got: $LOG_FILE_OVERRIDE)" >&2; exit "$EXIT_ENV" ;;
    esac
    [ -L "$LOG_FILE_OVERRIDE" ] && { echo "ERROR: --log-file must not be a symlink" >&2; exit "$EXIT_ENV"; }
    LOG_FILE="$LOG_FILE_OVERRIDE"
    : > "$LOG_FILE" 2>/dev/null || { echo "ERROR: cannot write log: $LOG_FILE" >&2; exit "$EXIT_ENV"; }
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  else
    LOG_FILE=$(mktemp -p "${TMPDIR:-/var/tmp}" audiofix.XXXXXX.log 2>/dev/null || mktemp /var/tmp/audiofix.XXXXXX.log 2>/dev/null || mktemp /tmp/audiofix.XXXXXX.log 2>/dev/null) || { echo "ERROR: cannot create log file" >&2; exit "$EXIT_ENV"; }
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  fi
  # prune logs older than 7 days (best effort)
  find /tmp /var/tmp -maxdepth 1 -name 'audiofix.*.log' -o -maxdepth 1 -name 'audiofix-*.log' -mtime +7 -delete 2>/dev/null || true
}

log_plain() { printf '%s\n' "$1" >>"$LOG_FILE" 2>/dev/null || true; }
log() {
  local msg="$1"
  printf '%b\n' "$msg" | tee -a "$LOG_FILE" >/dev/null 2>&1 || printf '%b\n' "$msg"
  if [ "$QUIET" -eq 0 ]; then printf '%b\n' "$msg"; fi
}
# --- TTY UI (ASCII-only, color-gated) ---
# All helpers log a plain-ASCII twin so $LOG_FILE stays grep-friendly.
STEP_N=0
rule() {
  local w="${1:-${COLUMNS:-68}}" _rule
  [[ "$w" =~ ^[0-9]+$ ]] || w=68
  [ "$w" -gt 78 ] && w=78
  [ "$w" -lt 20 ] && w=68
  printf -v _rule '%*s' "$w" ""
  log "${C_DIM}${_rule// /-}${C_RESET}"; log_plain "----------------------------------------------------------------------"
}
banner() {
  # Calm header. Intro lines kept verbatim. No art, no duplicate title.
  SECONDS=0
  STEP_N=0
  log "${C_BOLD}AudioFix${C_RESET}"
  log "Fix audio issue in Linux based operating systems."
  log_plain "AudioFix"
  log_plain "Fix audio issue in Linux based operating systems."
  rule 68
  log "  Log : $LOG_FILE"
  if [ -n "${BACKUP_DIR:-}" ]; then log "  Backup : $BACKUP_DIR"; fi
  if [ "$DRY_RUN" -eq 1 ]; then log "  Mode: ${C_BOLD}${C_YELLOW}[ DRY-RUN ]${C_RESET} no changes will be made"; log_plain "  Mode: [ DRY-RUN ]"; fi
}
timer_fmt() { local s="${1:-0}"; printf '%02d:%02d' $((s/60)) $((s%60)); }
step() {
  # Calm: file always, screen only in --verbose. No rulers/timers by default.
  local title="$1"
  log_plain ""
  log_plain ">> ${title}"
  if [ "$VERBOSE" -eq 1 ]; then
    log ""
    log "${C_BOLD}${C_BLUE}>> ${title}${C_RESET}"
  fi
}
info() { log "${C_CYAN}   ::${C_RESET} $1"; log_plain "   :: $1"; }
ok()   { log "${C_GREEN}  [OK]${C_RESET} $1"; log_plain "  [OK] $1"; }
warn() { local m="$1"; log "${C_YELLOW}  [!!]${C_RESET} $m"; log_plain "  [!!] $m"; }
err()  { local m="$1"; printf '%s\n' "  [XX] $m" >>"$LOG_FILE" 2>/dev/null || true; printf '%b\n' "${C_RED}  [XX]${C_RESET} $m" >&2; }
die()  { err "$1"; exit "${2:-$EXIT_ENV}"; }
summary_box() {
  # Dynamic width box, ASCII-only. Top and bottom same length.
  local title="$1"; shift
  local line mx=0 w bar top
  for line in "$@"; do [ "${#line}" -gt "$mx" ] && mx="${#line}"; done
  [ "${#title}" -gt "$mx" ] && mx="${#title}"
  w=$((mx + 8)); [ "$w" -lt 50 ] && w=50; [ "$w" -gt 76 ] && w=76
  printf -v bar '%*s' "$w" ""; bar="${bar// /-}"
  printf -v top '+-- %s %s' "$title" "$bar"
  top="${top:0:$w}"
  log ""
  log "${C_BOLD}${C_GREEN}${top}${C_RESET}"
  for line in "$@"; do
    log "${C_BOLD}${C_GREEN}|${C_RESET} ${line}"
    log_plain "  ${line}"
  done
  log "${C_BOLD}${C_GREEN}${bar:0:$w}${C_RESET}"
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
  # $1 = question text (e.g. "Reboot now? [y/N]:"), $2 = default, $3 = var name
  # Never logs the answer (future-proof: answers could be sensitive).
  local question="$1" def="$2" __var="$3"
  local ans=""
  # Visible on screen even when stdin is piped: print explicitly, flush.
  # NOTE: no extra echo of $ans to /dev/tty here - the terminal already
  # echoes input in canonical mode, extra printf caused double "y" lines.
  printf '%s ' "$question" > /dev/tty 2>/dev/null || printf '%s ' "$question"
  log_plain "ASK: $question (default=${def})"
  if ! IFS= read -r -t 60 ans </dev/tty; then ans=""; fi
  ans="${ans:-$def}"
  printf -v "$__var" '%s' "$ans"
}
# --- Plain prompts only (no external TUI deps by design) ---
# gum/fzf/dialog intentionally not used: keep curl|bash predictable.
confirm_yn() {
  # $1 = question, $2 = default Y/N. Returns 0=yes, 1=no. Pure bash.
  local question="$1" def="$2" ans=""
  ask "$question" "$def" ans
  case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
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
    if [ "$QUIET" -eq 0 ]; then log "  \$ $*"; fi
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
    die "sudo not found and not running as root. Re-run as root." "$EXIT_ENV"
  fi
  if [ "$DRY_RUN" -eq 0 ] && [ "$LIST_CHIPS_ONLY" -eq 0 ]; then
    if ! sudo -v; then
      die "Could not acquire sudo privileges. Aborting." "$EXIT_ENV"
    fi
    ( while true; do sudo -v; sleep 60; done ) &
    SUDO_KEEPALIVE_PID=$!
  fi
  SUDO="sudo"
}
cleanup() {
  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi
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

chip_desc() {
  case "$1" in
    ALC255) echo "Most common laptop HDA (Acer/ASUS/Dell)" ;;
    ALC256|ALC3246) echo "Laptop HDA (ALC3246 = Dell rebrand of ALC256)" ;;
    ALC257) echo "ThinkPad X/T HDA (SSID bug 17aa:0000 common)" ;;
    ALC269) echo "Reference laptop HDA (huge kernel quirk table)" ;;
    ALC287|ALC3306) echo "Modern laptop HDA, often + CS35L41 smart-amp (Lenovo/ASUS/HP)" ;;
    ALC1220) echo "Flagship desktop HDA (incl. ALC1220P/VB, S1220A, ALC1250/ALC1200 family)" ;;
    ALC892|ALC897) echo "Common desktop HDA (budget/gaming boards)" ;;
    ALC4080|ALC4082) echo "USB 2.0 onboard audio (looks like HDA in specs, is USB)" ;;
    ALC4040|ALC4050|ALC4070) echo "USB headset/dongle/bridge" ;;
    RT5682|RT715|RT714|RT1318) echo "I2S/SoundWire companion (SOF firmware, not HDA)" ;;
    *) echo "Realtek audio codec" ;;
  esac
}

is_hda_safe() { [ "$(chip_iface "$1")" = "HDA" ]; }

# Generic EAPD/coef init verbs (original fix). Volatile - needs persistence.
GENERIC_VERBS=("0x20 0x500 0x1b" "0x20 0x477 0x4a4b" "0x20 0x500 0xf" "0x20 0x477 0x74")

# ---------------------------------------------------------------------------
# OS / package management (no sourcing os-release, apt update once)
# ---------------------------------------------------------------------------
OS_ID=""; OS_LIKE=""; APT_UPDATED=0
detect_os() {
  if [ -f /etc/os-release ]; then
    OS_ID=$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | LC_ALL=C tr -d '"' | LC_ALL=C tr '[:upper:]' '[:lower:]' || true)
    OS_LIKE=$(grep -E '^ID_LIKE=' /etc/os-release 2>/dev/null | cut -d= -f2 | LC_ALL=C tr -d '"' | LC_ALL=C tr '[:upper:]' '[:lower:]' || true)
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
      warn "Unrecognized distro (ID=${OS_ID:-?} LIKE=${OS_LIKE:-?}). Trying known managers in order..."
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
  step "[1/6] Checking dependencies"
  detect_os
  info "Distro: ID=${OS_ID:-unknown} LIKE=${OS_LIKE:-none}"
  if ! command -v alsamixer &>/dev/null; then
    info "Installing alsa-utils..."
    pkg_install alsa-utils || die "Failed to install alsa-utils" "$EXIT_PKG"
    if ! command -v alsamixer &>/dev/null && [ "$DRY_RUN" -eq 0 ]; then
      die "alsa-utils install reported success but alsamixer still missing" "$EXIT_PKG"
    fi
  else ok "alsamixer found ($(command -v alsamixer))"; fi
  if ! command -v hda-verb &>/dev/null; then
    info "Installing alsa-tools (provides hda-verb)..."
    pkg_install alsa-tools || die "Failed to install alsa-tools" "$EXIT_PKG"
    if ! command -v hda-verb &>/dev/null && [ "$DRY_RUN" -eq 0 ]; then
      die "alsa-tools install reported success but hda-verb still missing" "$EXIT_PKG"
    fi
  else ok "hda-verb found ($(command -v hda-verb))"; fi
  # diag tools are best-effort (detection still works without them)
  if ! command -v lspci &>/dev/null || ! command -v lsusb &>/dev/null; then
    info "Installing pciutils/usbutils for better detection (best effort)..."
    pkg_install diag || warn "Could not install diag tools; detection will use fallbacks"
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
  step "[2/6] Detecting Realtek audio"
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
    warn "No codec in /proc/asound; trying 'aplay -l' fallback (LOW confidence)"
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
  if command -v lsusb &>/dev/null; then
    local usb_audio
    usb_audio=$(lsusb 2>/dev/null | grep -iE 'audio|headset|ALC40[0-9]{2}|0bda:.*(audio|4050|4040|4070|4080|4082)' || true)
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
  if [ -n "$USB_HINT" ]; then warn "USB audio hint: $USB_HINT"; fi
  if [ -n "$SOF_HINT" ]; then warn "SOF/smart-amp hint: $SOF_HINT (speakers may need SOF firmware/amp quirk, not just hda-verb)"; fi

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
    err "No Realtek codec detected."
    err "Tried: /proc/asound/card*/codec#*, aplay -l. Hints: USB='${USB_HINT:-none}' SOF='${SOF_HINT:-none}'"
    info "Tip: run with --list-chips, or force with --card N --chip ALCxxx --force"
    info "Tip: for ALC4080/82 (USB) see 'USB branch' in --help; for SOF laptops check sof-firmware"
    return "$EXIT_NO_CHIP"
  fi

  ok "Detected ${#FOUND_MODELS[@]} codec(s) via $FOUND_METHOD"
  for i in "${!FOUND_MODELS[@]}"; do
    log "  [$i] ${FOUND_MODELS[$i]} (card ${FOUND_CARDS[$i]})"
    log_plain "  [$i] ${FOUND_MODELS[$i]} ${FOUND_IFACES[$i]} card=${FOUND_CARDS[$i]} codec=${FOUND_CODECS[$i]}"
    if [ "$VERBOSE" -eq 1 ]; then
      log "      iface=${FOUND_IFACES[$i]} codec=${FOUND_CODECS[$i]}: $(chip_desc "${FOUND_MODELS[$i]}")"
    fi
  done
  if [ -n "$USB_HINT" ]; then
    warn "hda-verb only applies to HDA (PCI) codecs, NOT to USB audio. USB fix = UCM/PipeWire profile."
  fi
  return 0
}

list_chips() {
  if ! detect_chips; then exit "$EXIT_NO_CHIP"; fi
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
  # Calm wizard Q1 (only when ambiguous). Pure bash, max 2 prompts here.
  SELECTED_INDEX=0
  if [ "${#FOUND_MODELS[@]}" -gt 1 ] && [ -z "$OVERRIDE_CARD" ]; then
    log "Found ${#FOUND_MODELS[@]} codecs:"
    for i in "${!FOUND_MODELS[@]}"; do
      log "  [$i] ${FOUND_MODELS[$i]} (card ${FOUND_CARDS[$i]})"
    done
    if can_prompt; then
      local use="" sel=""
      ask "1/3 Use [0] ${FOUND_MODELS[0]} card ${FOUND_CARDS[0]}? [Y/n]:" "Y" use
      case "$use" in
        ""|[Yy]*)
          SELECTED_INDEX=0
          log_plain "CHOICE: default 0"
          ;;
        *)
          ask "Enter number [0-$(( ${#FOUND_MODELS[@]} - 1 ))]:" "0" sel
          if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -lt "${#FOUND_MODELS[@]}" ]; then
            SELECTED_INDEX="$sel"
          else
            warn "Bad choice, using 0"
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
  ok "Selected: $MODEL (iface=$IFACE) card=$CARD_NUM codec=$CODEC_NUM"
  info "Known quirk hint: model=$(chip_model_hint "$MODEL")"
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
BACKUP_STATE_FILE=""
backup_alsa() {
  step "[3/6] Backing up ALSA state"
  local base="${BACKUP_DIR:-}"
  if [ -z "$base" ]; then
    if [ -w /var/tmp 2>/dev/null ]; then base="/var/tmp/audiofix-backup-$(date +%Y%m%d-%H%M%S)-$$"
    else base="/tmp/audiofix-backup-$(date +%Y%m%d-%H%M%S)-$$"; fi
  fi
  case "$base" in
    /var/tmp/audiofix-backup-*|/tmp/audiofix-backup-*) ;;
    *) die "Refusing backup outside /var/tmp/audiofix-backup-* or /tmp/audiofix-backup-* (got: $base). Use --backup-dir with one of those prefixes." "$EXIT_ENV" ;;
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
      ok "ALSA state backed up to $BACKUP_STATE_FILE"
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
  step "[4/6] Fixing ALSA mixer (Auto-Mute + unmute)"
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
    info "Auto-Mute: $fixed/$total off"
  fi

  info "Unmuting essentials (Master/Headphone/Speaker/PCM @80%)..."
  for ctl in Master Headphone Speaker PCM Front; do
    if amixer -c "$CARD_NUM" scontrols 2>/dev/null | grep -q "'$ctl'"; then
      if [ "$DRY_RUN" -eq 1 ]; then log "  (dry-run) would run: amixer -c $CARD_NUM sset $ctl 80% unmute"
      else amixer -c "$CARD_NUM" sset "$ctl" 80% unmute >>"$LOG_FILE" 2>&1 || warn "Could not unmute $ctl"; fi
    fi
  done
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
  step "[5/6] Running hda-verb init (HDA only)"
  if [ "$IFACE" = "USB" ]; then
    warn "$MODEL is USB audio (iface=USB). hda-verb does NOT apply."
    info "USB path: check 'alsamixer -c $CARD_NUM', PipeWire profile, and UCM:"
    info "  cat /proc/asound/card${CARD_NUM}/usbmixer 2>/dev/null | head -20"
    info "  grep -R ALC4080 /usr/share/alsa/ucm2/USB-Audio/ 2>/dev/null | head"
    info "  Your board USB ID must be in USB-Audio.conf profile; else append VID:PID and restart pipewire."
    if [ "$FORCE" -eq 0 ]; then warn "Skipping hda-verb (use --force to override, not recommended)"; return 0; fi
  fi
  if [ "$IFACE" = "SOF" ]; then
    warn "$MODEL is I2S/SoundWire (iface=SOF). hda-verb does NOT apply."
    info "SOF path: install sof-firmware/SOF topology, try:"
    info "  options snd-intel-dspcfg dsp_driver=1  (or =3) in /etc/modprobe.d, then reboot"
    if [ "$FORCE" -eq 0 ]; then warn "Skipping hda-verb (use --force to override)"; return 0; fi
  fi
  if [ "$MODEL" = "UNKNOWN-MODEL" ] || [ "$MODEL" = "UNKNOWN" ] || [ "$IFACE" = "UNKNOWN" ]; then
    warn "Chip model unknown (model=$MODEL iface=$IFACE). Generic verbs may mis-pin codec."
    if [ "$FORCE" -eq 0 ]; then
      die "Refusing to run generic verbs on unknown codec. Re-run with --chip ALCxxx --force (see --list-chips)." "$EXIT_VERB"
    fi
    warn "--force given: proceeding on unknown codec"
  fi
  if [ "$APPLY_VERBS_ONLY" -eq 0 ] && [ -n "$SOF_HINT" ]; then
    warn "Smart-amp/SOF marker present: $SOF_HINT"
    warn "hda-verb alone may not fix speakers (needs CS35L41/amp quirk + kernel >=6.x). Continuing with verbs anyway."
  fi

  local hda_dev
  if ! hda_dev=$(resolve_hda_dev); then
    die "No /dev/snd/hwC${CARD_NUM}D* node exists (card=$CARD_NUM codec=$CODEC_NUM). Is snd-hda-intel loaded?" "$EXIT_VERB"
  fi
  if [ "$hda_dev" != "/dev/snd/hwC${CARD_NUM}D${CODEC_NUM}" ]; then
    warn "Exact node hwC${CARD_NUM}D${CODEC_NUM} missing; using $hda_dev (verified fallback)"
  fi
  info "Target device: $hda_dev ($MODEL)"
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
    else warn "hda-verb failed: $cmd"; fail_count=$((fail_count+1)); fi
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
    if [ "$APPLY_VERBS_ONLY" -eq 1 ]; then return "$EXIT_VERB"; fi
  fi
  # Record for persistence step
  HDA_DEV_USED="$hda_dev"
}

# ---------------------------------------------------------------------------
# Persistence: modprobe quirk + systemd replay (verbs are volatile)
# ---------------------------------------------------------------------------
persist_fix() {
  step "[6/6] Persistence (survive reboot/suspend)"
  if [ "$PERSIST" = "no" ]; then info "Skipped (--no-persist)"; return 0; fi
  # Decided upfront in main (wizard Q2). Never asks here.
  if [ "$PERSIST" = "prompt" ]; then PERSIST="yes"; fi
  if [ "$IFACE" = "USB" ] || [ "$IFACE" = "SOF" ]; then
    warn "Persistence for $IFACE is UCM/SOF based, not modprobe/hda-verb. Skipping unit install."
    info "USB: add VID:PID to /usr/share/alsa/ucm2/USB-Audio/USB-Audio.conf"
    info "SOF: /etc/modprobe.d/sof-fix.conf -> options snd-intel-dspcfg dsp_driver=3"
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
    if [ "$VERBOSE" -eq 1 ]; then
      if printf '%s' "$automute_state" | grep -q "Disabled"; then ok "Auto-Mute reads Disabled"
      else info "amixer Auto-Mute state: ${automute_state:-unknown}"; fi
    fi
  fi
  if command -v aplay &>/dev/null; then LC_ALL=C aplay -l 2>/dev/null | head -10 >>"$LOG_FILE" 2>/dev/null || true; fi
  dmesg 2>/dev/null | grep -iE 'snd|hda|sof|ALC|CSC3551' | tail -5 >>"$LOG_FILE" 2>/dev/null || true
  if [ "$VERBOSE" -eq 1 ]; then info "Play any audio to confirm sound works after reboot."; fi
}

do_uninstall() {
  step "Uninstalling AudioFix persistence"
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
    case "$BACKUP_STATE_FILE" in
      /var/tmp/audiofix-backup-*|/tmp/audiofix-backup-*)
        if $SUDO alsactl restore -f "$BACKUP_STATE_FILE" >>"$LOG_FILE" 2>&1; then ok "Restored $BACKUP_STATE_FILE"; fi ;;
      *) warn "Refusing to restore from unexpected path: $BACKUP_STATE_FILE" ;;
    esac
  else
    local latest=""
    latest=$(find /var/tmp /tmp -maxdepth 2 -name 'asound.state.*' -path '*audiofix-backup-*' -print 2>/dev/null | head -n1 || true)
    if [ -n "$latest" ]; then
      case "$latest" in
        /var/tmp/audiofix-backup-*|/tmp/audiofix-backup-*)
          info "Found backup $latest"
          if $SUDO alsactl restore -f "$latest" >>"$LOG_FILE" 2>&1; then ok "Restored $latest"; else warn "Restore failed"; fi ;;
        *) warn "Refusing to restore from unexpected path" ;;
      esac
    else info "No ALSA backup found to restore"; fi
  fi
}

handle_reboot() {
  log "  Log: $LOG_FILE"
  if [ -n "${BACKUP_DIR:-}" ]; then log "  Backup: $BACKUP_DIR"; fi
  log_plain "Log: $LOG_FILE"
  if [ "$NO_REBOOT" -eq 1 ]; then info "Reboot skipped (--dry-run/--no-reboot). Reboot manually: sudo reboot"; return 0; fi
  # Decided upfront in main (wizard Q3). Never asks here.
  if [ "$DO_REBOOT" -eq 1 ] || [ "${WANT_REBOOT:-N}" = "Y" ]; then
    ok "Rebooting in 5s (Ctrl+C to cancel)..."
    sleep 5
    cleanup
    if command -v systemctl &>/dev/null; then $SUDO systemctl reboot || $SUDO reboot
    else $SUDO reboot; fi
    return 0
  fi
  info "Done. Reboot manually when convenient: sudo reboot"
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
  trap 'cleanup; trap - EXIT INT TERM HUP; err "AudioFix failed (see log)"; exit $EXIT_ENV' ERR
  trap cleanup INT TERM HUP

  echo ""
  banner
  echo ""

  if [ "$UNINSTALL" -eq 1 ]; then
    init_sudo
    do_uninstall
    handle_reboot
    exit "$EXIT_OK"
  fi

  if [ "$LIST_CHIPS_ONLY" -eq 1 ]; then
    list_chips
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
  ensure_deps
  detect_chips || exit "$EXIT_NO_CHIP"
  choose_chip

  if [ "$DRY_RUN" -eq 1 ]; then info "DRY-RUN: no changes will be made"; fi

  log "Fix will: unmute, turn off Auto-Mute, run init."
  log_plain "Plan: unmute + Auto-Mute off + hda-verb init"
  if can_prompt; then
    if [ "$PERSIST" = "prompt" ]; then
      if confirm_yn "2/3 Keep fix after reboot? [Y/n]:" "Y"; then PERSIST="yes"; else PERSIST="no"; fi
    fi
    if [ "$DO_REBOOT" -eq 0 ] && [ "$NO_REBOOT" -eq 0 ]; then
      if confirm_yn "3/3 Reboot when done? [y/N]:" "N"; then WANT_REBOOT="Y"; else WANT_REBOOT="N"; fi
    elif [ "$DO_REBOOT" -eq 1 ]; then
      WANT_REBOOT="Y"
    else
      WANT_REBOOT="N"
    fi
  else
    if [ "$PERSIST" = "prompt" ]; then PERSIST="yes"; fi
    if [ "$DO_REBOOT" -eq 1 ]; then WANT_REBOOT="Y"; else WANT_REBOOT="N"; fi
  fi

  log "Working..."
  log_plain "Working..."

  backup_alsa
  fix_alsa
  fix_hda_verbs || exit "$?"
  if [ "$PERSIST" != "no" ]; then persist_fix; else info "Persistence skipped (--no-persist)"; fi
  verify_fix

  log "Done: unmuted, Auto-Mute ${AUTOMUTE_DONE}/${AUTOMUTE_TOTAL} off, init ${VERBS_OK}/${VERBS_TOTAL}. Reboot: $([ "$WANT_REBOOT" = "Y" ] && echo yes || echo no)."
  log_plain "Done: model=$MODEL card=$CARD_NUM verbs=$VERBS_OK/$VERBS_TOTAL reboot=$WANT_REBOOT"
  if [ "$IFACE" != "HDA" ]; then warn "$MODEL is $IFACE - see USB/SOF guidance above."; fi
  if [ -n "$SOF_HINT" ]; then warn "SOF/amp hint - check sof-firmware + CS35L41 quirk."; fi
  log "Log: $LOG_FILE"
  log_plain "Log: $LOG_FILE"

  handle_reboot
}

main "$@"
