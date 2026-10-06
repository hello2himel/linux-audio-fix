# AudioFix

Fix audio issue in Linux based operating systems.

![Stars](https://img.shields.io/github/stars/hello2himel/linux-audio-fix?style=flat-square)
![Forks](https://img.shields.io/github/forks/hello2himel/linux-audio-fix?style=flat-square)
![Issues](https://img.shields.io/github/issues/hello2himel/linux-audio-fix?style=flat-square)
![Last commit](https://img.shields.io/github/last-commit/hello2himel/linux-audio-fix?style=flat-square)
![Bash](https://img.shields.io/badge/shell-bash-green?style=flat-square&logo=gnu-bash)
![Linux](https://img.shields.io/badge/platform-linux-blue?style=flat-square&logo=linux)
![Visitors](https://komarev.com/ghpvc/?username=hello2himel&repo=linux-audio-fix&color=blue&style=flat-square)

> Visitor counter via `komarev.com/ghpvc`. Alternative: `https://visitor-badge.laobi.icu/badge?page_id=hello2himel.linux-audio-fix`

Realtek HDA fix: disables Auto-Mute, unmutes essentials, runs EAPD/coef `hda-verb` init, installs boot persistence (modprobe + systemd replay).

## Quick run

```bash
curl -fsSL https://raw.githubusercontent.com/hello2himel/linux-audio-fix/main/AudioFix.sh | bash
```

```bash
./AudioFix.sh --list-chips
./AudioFix.sh --dry-run --verbose
./AudioFix.sh
./AudioFix.sh --yes --reboot
./AudioFix.sh --card 1 --chip ALC256 --force
./AudioFix.sh --uninstall
```

No prompts hidden: questions print to `/dev/tty` then read from `/dev/tty`. `--yes` / non-TTY / `--dry-run` uses defaults, never blocks.

## What it does

1. `[1/6]` Deps: `alsa-utils`, `alsa-tools`, `pciutils/usbutils` (arch/debian/fedora/suse/gentoo/alpine/void, NixOS aborts with instructions).
2. `[2/6]` Detect: `/proc/asound/card*/codec#*` (`0x10ec`), fallback `aplay -l`, USB/SOF hints. 70+ HDA chips allowlisted, USB `ALC4080/4082/4040/4050` and SOF `RT5682/715/714/1318` safely skipped with UCM/SOF guidance.
3. `[3/6]` Backup to `/var/tmp/audiofix-backup-*`.
4. `[4/6]` Disable all Auto-Mute controls (`Disabled`/`Off` + verify), unmute Master/Headphone/Speaker/PCM 80%, `alsactl store`.
5. `[5/6]` `hda-verb` GET probe + 4 generic verbs on verified `/dev/snd/hwCxDy`. Unknown codecs require `--force`.
6. `[6/6]` Persistence: `/etc/modprobe.d/alsa-fix.conf` + `audiofix-hdaverb.service` replay. `--no-persist` to skip.

Exit codes: `0 ok | 1 env | 2 no chip | 3 pkg fail | 4 verb fail`. Log: `/tmp/audiofix-*.log` (`--log-file PATH`).

## Manual method

If auto fails, see original steps: BIOS update, `alsamixer` (F6 select card, Auto-Mute Disabled), `alsa-tools`, then:

```bash
sudo hda-verb /dev/snd/hwC0D0 0x20 0x500 0x1b
sudo hda-verb /dev/snd/hwC0D0 0x20 0x477 0x4a4b
sudo hda-verb /dev/snd/hwC0D0 0x20 0x500 0xf
sudo hda-verb /dev/snd/hwC0D0 0x20 0x477 0x74
sudo reboot
```

![Disable Auto-Mute](res/disableAutomute.gif)

## FAQ

- USB `ALC4080/82`? `hda-verb` does not apply. Check UCM `USB-Audio.conf` VID:PID + PipeWire profile.
- SOF / `CSC3551` / smart-amp? Needs `sof-firmware` + amp quirk, not just verbs.
- Confirm sound? Play any audio after the fix, reboot if still silent.
- Revert? `--uninstall` removes conf/unit and restores ALSA backup.
