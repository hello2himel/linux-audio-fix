#!/bin/bash

echo "🔧 Starting Linux Audio Fix..."

# Step 1: Install necessary packages
echo "📦 Installing alsa-utils and alsa-tools if missing..."
if ! command -v alsamixer &> /dev/null; then
    echo "🔹 Installing alsa-utils..."
    sudo pacman -S --noconfirm alsa-utils || sudo apt-get install -y alsa-utils || sudo dnf install -y alsa-utils
    sleep 3  # Artificial delay
fi
if ! command -v hda-verb &> /dev/null; then
    echo "🔹 Installing alsa-tools..."
    sudo pacman -S --noconfirm alsa-tools || sudo apt-get install -y alsa-tools || sudo dnf install -y alsa-tools
    sleep 3  # Artificial delay
fi

# Step 2: Detect Realtek Audio Chip
echo "🔍 Detecting Realtek Audio chip..."
realtek_models="ALC1220 ALC1150 ALC882 ALC883 ALC885 ALC886 ALC887 ALC888 ALC889 ALC892 ALC899 ALC861VD ALC891 ALC900 ALC660 ALC662 ALC663 ALC665 ALC667 ALC668 ALC670 ALC671 ALC672 ALC676 ALC680 ALC221 ALC231 ALC233 ALC235 ALC236 ALC255 ALC256 ALC260 ALC262 ALC267 ALC268 ALC269 ALC270 ALC272 ALC273 ALC275 ALC276 ALC280 ALC282 ALC283 ALC284 ALC286 ALC288 ALC290 ALC292 ALC293 ALC298 ALC383 ALC897"

audio_devices=$(aplay -l | grep -i card)
found_realtek=0
for model in $realtek_models; do
    if echo "$audio_devices" | grep -i "$model" > /dev/null; then
        echo "✅ Realtek Audio Chip detected: $model"
        found_realtek=1
        break
    fi
done

if [ $found_realtek -eq 0 ]; then
    echo "❌ No Realtek Audio chip detected. Exiting..."
    exit 1
fi
sleep 2  # Artificial delay

# Step 3: Get Sound Card Index
card_num=$(aplay -l | grep "$model" | awk '{print $2}' | sed 's/://')

if [ -z "$card_num" ]; then
    echo "❌ Could not determine the sound card number."
    exit 1
fi
echo "🎵 Sound card index: $card_num"
sleep 2  # Artificial delay

# Step 4: Disable Auto-Mute
if amixer -c "$card_num" controls | grep -qi "Auto-Mute"; then
    echo "🔇 Disabling Auto-Mute..."
    amixer -c "$card_num" sset 'Auto-Mute Mode' Disabled
    sudo alsactl store
    echo "✅ Auto-Mute disabled!"
else
    echo "⚠️ No Auto-Mute setting found. Skipping..."
fi
sleep 2  # Artificial delay

# Step 5: Run hda-verb commands
echo "⚡ Running hda-verb commands..."
sudo hda-verb /dev/snd/hwC0D0 0x20 0x500 0x1b
sudo hda-verb /dev/snd/hwC0D0 0x20 0x477 0x4a4b
sudo hda-verb /dev/snd/hwC0D0 0x20 0x500 0xf
sudo hda-verb /dev/snd/hwC0D0 0x20 0x477 0x74
echo "✅ hda-verb commands executed!"
sleep 3  # Artificial delay

# Step 6: Reboot Confirmation
while true; do
    read -rp "🔄 Do you want to reboot the system now? (Y/n): " choice
    choice=${choice:-Y}  # Default to 'Y' if no input is given
    case "$choice" in
        [Yy]*)
            echo "♻ Rebooting system in 5 seconds..."
            sleep 5
            sudo reboot
            exit
            ;;
        [Nn]*)
            echo "❌ System reboot aborted. You can reboot later manually."
            exit
            ;;
        *)
            echo "❗ Invalid input. Please enter 'Y' for Yes or 'N' for No."
            ;;
    esac
done

