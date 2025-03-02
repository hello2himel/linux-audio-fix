# Linux Audio Fix

This repository provides a script to help you fix issues with Realtek audio drivers in Linux. There are two ways to resolve the issue: one automated and one manual method.

## 1. Automated Method

The automated method allows you to fix the issue by simply running a script. Follow these steps:

### Step-by-Step:

1. **Clone the repository:**
   ```bash
   git clone https://github.com/hello2himel/linux-audio-fix.git
   ```

2. **Navigate to the cloned directory:**
   ```bash
   cd linux-audio-fix
   ```

3. **Give execute permission to the script:**
   ```bash
   chmod +x AudioFix.sh
   ```

4. **Run the script:**
   ```bash
   ./AudioFix.sh
   ```

The script will automatically install the necessary tools, detect the Realtek chip, disable auto-mute, run `hda-verb` commands, and reboot your system.

---

## 2. Manual Method

If the automated method does not resolve your issue, you can follow the manual process below to fix your Realtek Audio drivers.

### Step-by-Step:

1. **Update Your Motherboard BIOS:**
   Ensure that your motherboard BIOS is updated to the latest version. Check your motherboard manufacturer's website for the latest BIOS update instructions.

2. **Install alsa-utils (if not already installed):**
   Open your terminal and type the following command to install `alsa-utils`. For Arch-based systems, use:
   ```bash
   sudo pacman -S alsa-utils
   ```

   For other distros like Ubuntu/Fedora, `alsa-utils` might come pre-installed.

3. **Launch alsamixer:**
   In your terminal, type `alsamixer` and press enter. If the terminal doesn't detect the command, ensure that `alsa-utils` is installed.

4. **Select the Realtek Sound Card:**
   - After launching `alsamixer` in your terminal, press `F6` to open the **"Select Sound Card"** menu.
   - You will see a list of available sound cards. The names might be generic, such as **"HD-Audio Generic"** or similar, depending on your system's configuration.
   - Use the **arrow keys** to navigate through the list of sound cards. Once you highlight a card, press **Enter** to select it.
   - After selecting a card, if it's a Realtek chip, you'll see its details in the new menu (such as **ALC897**, **ALC1220**, etc.). This confirms that you have selected the correct Realtek sound card.

   If the selected card is not a Realtek chip, you may need to check the system's audio hardware to ensure the correct card is selected.

   **Here’s a tutorial showing how to disable Auto-Mute: (The video may take a while to load, please wait)**

   ![Disable Auto-Mute](res/disableAutomute.gif)


5. **Disable Auto-Mute:**
   Using the arrow keys, navigate to the **Auto-Mute** option on the right side and disable it by pressing the `UP/DOWN` arrow keys. Press `ESC` to exit `alsamixer`.

6. **Install hda-verb (if not already installed):**
   You need to install `hda-verb` for running specific commands. Install it using the following commands:
   
   For **Debian/Ubuntu/Raspbian/Kali Linux**:
   ```bash
   sudo apt-get install alsa-tools
   ```

   For **Arch Linux**:
   ```bash
   sudo pacman -S alsa-tools
   ```

   For **Fedora**:
   ```bash
   sudo dnf install alsa-tools
   ```

7. **Run the following `hda-verb` commands:**
   These commands are used to modify audio configurations.
   ```bash
   sudo hda-verb /dev/snd/hwC0D0 0x20 0x500 0x1b
   sudo hda-verb /dev/snd/hwC0D0 0x20 0x477 0x4a4b
   sudo hda-verb /dev/snd/hwC0D0 0x20 0x500 0xf
   sudo hda-verb /dev/snd/hwC0D0 0x20 0x477 0x74
   ```

8. **Reboot Your System:**
   After executing the commands, reboot your system to apply the changes:
   ```bash
   sudo reboot
   ```

---

## Conclusion

If the automated method doesn't work for you, follow the manual steps to resolve the issue. By disabling auto-mute and running `hda-verb` commands, you should be able to fix the Realtek audio driver issue on Linux.

---
