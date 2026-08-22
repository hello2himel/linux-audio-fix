#!/usr/bin/env bash
#
# AudioFix.sh - Realtek HDA audio auto-mute / codec fix
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/hello2himel/linux-audio-fix/main/AudioFix.sh | bash
#   ./AudioFix.sh [--dry-run] [--yes] [--no-reboot] [--verbose]
#
set -uo pipefail  # NOT -e: we want to handle failures ourselves and keep going where safe

# ---------------------------------------------------------------------------
# Config / flags
# ---------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
NO_REBOOT=0
VERBOSE=0
LOG_FILE="/tmp/audiofix-$(date +%Y%m%d-%H%M%S).log"

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --no-reboot) NO_REBOOT=1 ;;
        --verbose|-v) VERBOSE=1 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--dry-run] [--yes] [--no-reboot] [--verbose]
  --dry-run     Show what would happen, change nothing
  --yes         Don't prompt for reboot confirmation (assume yes)
  --no-reboot   Never reboot, regardless of prompt
  --verbose     Print extra diagnostic detail
EOF
            exit 0
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()   { echo -e "$1" | tee -a "$LOG_FILE"; }
info()  { log "🔹 $1"; }
ok()    { log "✅ $1"; }
warn()  { log "⚠️  $1"; }
err()   { log "❌ $1"; }
run() {
    # Wraps a command: respects --dry-run, logs stderr, returns real exit code
    if [ "$DRY_RUN" -eq 1 ]; then
        log "   (dry-run) would run: $*"
        return 0
    fi
    if [ "$VERBOSE" -eq 1 ]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        return "${PIPESTATUS[0]}"
    else
        "$@" >>"$LOG_FILE" 2>&1
        return $?
    fi
}

info "Log file: $LOG_FILE"
echo "🔧 Starting Linux Audio Fix..."

# ---------------------------------------------------------------------------
# Sanity: are we in a real terminal, or piped (curl | bash)?
# If stdin isn't a TTY, later prompts must read from /dev/tty instead,
# or we silently default to "no reboot" for safety.
# ---------------------------------------------------------------------------
INTERACTIVE=1
if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
    INTERACTIVE=0
    warn "No interactive terminal detected (likely running via curl | bash)."
    warn "Reboot prompt will be skipped; system will NOT reboot automatically."
fi

# ---------------------------------------------------------------------------
# Sudo pre-flight: ask once up front instead of surprising the user mid-script
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
    if ! sudo -v; then
        err "Could not acquire sudo privileges. Aborting."
        exit 1
    fi
    # Keep sudo alive in the background for the duration of the script
    ( while true; do sudo -v; sleep 60; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
fi

# ---------------------------------------------------------------------------
# Step 1: Detect distro and install required packages
# ---------------------------------------------------------------------------
install_pkg() {
    local pkg="$1"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID_LIKE $ID" in
            *arch*)   run sudo pacman -S --noconfirm "$pkg" ;;
            *debian*|*ubuntu*) run sudo apt-get update -qq && run sudo apt-get install -y "$pkg" ;;
            *fedora*|*rhel*)   run sudo dnf install -y "$pkg" ;;
            *)
                warn "Unrecognized distro (ID=$ID, ID_LIKE=$ID_LIKE). Trying all package managers..."
                run sudo pacman -S --noconfirm "$pkg" ||
                run sudo apt-get install -y "$pkg" ||
                run sudo dnf install -y "$pkg"
                ;;
        esac
    else
        warn "/etc/os-release not found; trying all package managers..."
        run sudo pacman -S --noconfirm "$pkg" ||
        run sudo apt-get install -y "$pkg" ||
        run sudo dnf install -y "$pkg"
    fi
}

echo "📦 Checking for alsa-utils and alsa-tools..."

if ! command -v alsamixer &>/dev/null; then
    info "Installing alsa-utils..."
    install_pkg alsa-utils
    if ! command -v alsamixer &>/dev/null && [ "$DRY_RUN" -eq 0 ]; then
        err "alsa-utils install failed (alsamixer still not found). Aborting."
        exit 1
    fi
fi

if ! command -v hda-verb &>/dev/null; then
    info "Installing alsa-tools..."
    install_pkg alsa-tools
    if ! command -v hda-verb &>/dev/null && [ "$DRY_RUN" -eq 0 ]; then
        err "alsa-tools install failed (hda-verb still not found). Aborting."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: Detect Realtek Audio chip(s) — robust method
#
# Priority order:
#   1. /proc/asound/card*/codec#* -> Vendor Id (authoritative, vendor 10ec)
#   2. Same path, regex the model number generically (ALC\d+[A-Z]*)
#   3. USB Realtek audio controllers (vendor 0bda) via lsusb
#   4. Fallback: aplay -l text parsing (low confidence, explicitly flagged)
# ---------------------------------------------------------------------------
echo "🔍 Detecting Realtek Audio chip(s)..."

declare -a FOUND_CARD_NUMS=()
declare -a FOUND_CODEC_NUMS=()
declare -a FOUND_MODELS=()
DETECTION_METHOD=""

if compgen -G "/proc/asound/card*/codec#*" > /dev/null 2>&1; then
    for codec_path in /proc/asound/card*/codec#*; do
        [ -f "$codec_path" ] || continue
        vendor_id=$(grep -m1 -i "Vendor Id" "$codec_path" 2>/dev/null | grep -oP '0x\K[0-9a-fA-F]+')
        codec_name_line=$(grep -m1 -i "Codec:" "$codec_path" 2>/dev/null)

        is_realtek=0
        if [[ "$vendor_id" =~ ^10ec ]]; then
            is_realtek=1
        elif echo "$codec_name_line" | grep -qi "realtek"; then
            is_realtek=1
        fi

        if [ "$is_realtek" -eq 1 ]; then
            model=$(echo "$codec_name_line" | grep -oP 'ALC[0-9]+[A-Za-z]*' | head -1)
            [ -z "$model" ] && model="unknown-model"

            if [[ "$codec_path" =~ card([0-9]+)/codec#([0-9]+) ]]; then
                FOUND_CARD_NUMS+=("${BASH_REMATCH[1]}")
                FOUND_CODEC_NUMS+=("${BASH_REMATCH[2]}")
                FOUND_MODELS+=("$model")
            fi
        fi
    done
    [ "${#FOUND_MODELS[@]}" -gt 0 ] && DETECTION_METHOD="proc-asound (high confidence)"
fi

# Fallback: aplay -l text parsing, only if nothing found above
if [ "${#FOUND_MODELS[@]}" -eq 0 ]; then
    warn "No codec info in /proc/asound; falling back to 'aplay -l' text parsing (LOW confidence)."
    if command -v aplay &>/dev/null; then
        while IFS= read -r line; do
            model=$(echo "$line" | grep -oP 'ALC[0-9]+[A-Za-z]*' | head -1)
            if [ -n "$model" ]; then
                card_num=$(echo "$line" | grep -oP '^card \K[0-9]+')
                if [ -n "$card_num" ]; then
                    FOUND_CARD_NUMS+=("$card_num")
                    FOUND_CODEC_NUMS+=("0")  # unknown device index in this fallback path
                    FOUND_MODELS+=("$model")
                fi
            fi
        done < <(aplay -l 2>/dev/null | grep -i card)
    fi
    [ "${#FOUND_MODELS[@]}" -gt 0 ] && DETECTION_METHOD="aplay-l fallback (low confidence)"
fi

# Also check for USB Realtek audio (vendor 0bda) — informational only, since
# the hda-verb codec-register approach below does not apply to USB audio.
if command -v lsusb &>/dev/null; then
    if lsusb 2>/dev/null | grep -qi "0bda"; then
        warn "A Realtek USB audio device (vendor 0bda) was also detected."
        warn "This script's hda-verb fix only applies to HDA (PCI) codecs, not USB audio."
    fi
fi

if [ "${#FOUND_MODELS[@]}" -eq 0 ]; then
    err "No Realtek audio chip detected. Exiting."
    exit 1
fi

ok "Detected ${#FOUND_MODELS[@]} Realtek codec(s) via: $DETECTION_METHOD"
for i in "${!FOUND_MODELS[@]}"; do
    log "   [$i] Model: ${FOUND_MODELS[$i]}  Card: ${FOUND_CARD_NUMS[$i]}  Codec#: ${FOUND_CODEC_NUMS[$i]}"
done

# If multiple codecs found, let the user pick (or default to first, non-interactively)
SELECTED_INDEX=0
if [ "${#FOUND_MODELS[@]}" -gt 1 ]; then
    if [ "$INTERACTIVE" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
        echo "Multiple Realtek codecs found. Select one to fix:"
        for i in "${!FOUND_MODELS[@]}"; do
            echo "  [$i] ${FOUND_MODELS[$i]} (card ${FOUND_CARD_NUMS[$i]})"
        done
        read -rp "Enter number [0]: " sel < /dev/tty
        [ -n "$sel" ] && SELECTED_INDEX="$sel"
    else
        warn "Multiple codecs found; non-interactive mode, defaulting to first: ${FOUND_MODELS[0]}"
    fi
fi

model="${FOUND_MODELS[$SELECTED_INDEX]}"
card_num="${FOUND_CARD_NUMS[$SELECTED_INDEX]}"
codec_num="${FOUND_CODEC_NUMS[$SELECTED_INDEX]}"

ok "Using card $card_num / codec#$codec_num ($model)"

# ---------------------------------------------------------------------------
# Step 3: Disable Auto-Mute (search for any plausible control name)
# ---------------------------------------------------------------------------
echo "🔇 Checking Auto-Mute settings on card $card_num..."

AUTO_MUTE_CONTROL=$(amixer -c "$card_num" controls 2>/dev/null | grep -oiP "'[^']*Auto-Mute[^']*'" | tr -d "'" | head -1)

if [ -n "$AUTO_MUTE_CONTROL" ]; then
    info "Found control: '$AUTO_MUTE_CONTROL'"
    if run amixer -c "$card_num" sset "$AUTO_MUTE_CONTROL" Disabled; then
        if run sudo alsactl store; then
            ok "Auto-Mute disabled and state saved."
        else
            warn "Auto-Mute disabled but 'alsactl store' failed; change may not persist across reboot."
        fi
    else
        warn "Found an Auto-Mute control but failed to disable it. Continuing anyway."
    fi
else
    warn "No Auto-Mute control found on card $card_num. Skipping."
fi

# ---------------------------------------------------------------------------
# Step 4: Run hda-verb commands against the correct, verified device node
# ---------------------------------------------------------------------------
HDA_DEV="/dev/snd/hwC${card_num}D${codec_num}"
echo "⚡ Preparing hda-verb commands for $HDA_DEV..."

if [ ! -e "$HDA_DEV" ]; then
    err "Device node $HDA_DEV does not exist. Skipping hda-verb step."
    err "(Codec detection found card=$card_num codec=$codec_num, but no matching /dev/snd node.)"
else
    HDA_OK=1
    HDA_CMDS=(
        "0x20 0x500 0x1b"
        "0x20 0x477 0x4a4b"
        "0x20 0x500 0xf"
        "0x20 0x477 0x74"
    )
    for cmd in "${HDA_CMDS[@]}"; do
        # shellcheck disable=SC2086
        if ! run sudo hda-verb "$HDA_DEV" $cmd; then
            HDA_OK=0
            warn "hda-verb command failed: $cmd"
        fi
    done
    if [ "$HDA_OK" -eq 1 ]; then
        ok "All hda-verb commands executed successfully."
    else
        warn "One or more hda-verb commands failed. Check $LOG_FILE for details."
    fi
fi

# ---------------------------------------------------------------------------
# Step 5: Reboot confirmation
# Reads from /dev/tty explicitly so this works correctly even when the
# script itself was invoked via `curl | bash` (stdin is the pipe, not a TTY).
# ---------------------------------------------------------------------------
echo ""
echo "Summary of changes has been logged to: $LOG_FILE"

if [ "$NO_REBOOT" -eq 1 ]; then
    info "Reboot skipped (--no-reboot given). Reboot manually when convenient."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run complete. No changes were made, no reboot will occur."
    exit 0
fi

if [ "$ASSUME_YES" -eq 1 ]; then
    info "Auto-reboot skipped by default for safety even with --yes."
    info "Run with no flags in an interactive terminal, or reboot manually, to apply changes fully."
    exit 0
fi

if [ "$INTERACTIVE" -eq 0 ]; then
    warn "Non-interactive session detected: will NOT reboot automatically."
    warn "Please reboot manually to fully apply the fix."
    exit 0
fi

while true; do
    read -rp "🔄 Do you want to reboot the system now? (y/N): " choice < /dev/tty
    choice=${choice:-N}   # default to N now — safer default than the original Y
    case "$choice" in
        [Yy]*)
            ok "Rebooting system in 5 seconds... (Ctrl+C to cancel)"
            sleep 5
            sudo reboot
            exit 0
            ;;
        [Nn]*)
            info "Reboot skipped. Remember to reboot manually to fully apply the fix."
            exit 0
            ;;
        *)
            err "Invalid input. Please enter 'y' or 'n'."
            ;;
    esac
done
