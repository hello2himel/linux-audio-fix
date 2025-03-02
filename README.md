# Linux Audio Fix

This repository provides a script to help you fix issues with Realtek audio drivers in Linux. There are two methods to resolve the issue: an automated method and a manual method.

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

If the automated method does not resolve your issue, you can follow the manual process below to fix your Realtek audio drivers.

### Step-by-Step:

1. **Update Your Motherboard BIOS:**
   Ensure that your motherboard BIOS is updated to the latest version. Check your motherboard manufacturer's website for the latest BIOS update instructions.

2. **Install alsa-utils (if not already installed):**
   Open your terminal and type the following command to install `alsa-utils`. For Arch-based systems, use:
   ```bash
   sudo pacman -S alsa-utils
   ```

   For other distributions like Ubuntu/Fedora, `alsa-utils` might already be installed.

3. **Launch alsamixer:**
   In your terminal, type `alsamixer` and press Enter. If the terminal doesn't detect the command, ensure that `alsa-utils` is installed.

4. **Select the Realtek Sound Card:**
   - After launching `alsamixer` in your terminal, press `F6` to open the **"Select Sound Card"** menu.
   - You will see a list of available sound cards. The names may appear generic, such as **"HD-Audio Generic"** or similar, depending on your system's configuration.
   - Use the **arrow keys** to navigate through the list of sound cards. Once you highlight a card, press **Enter** to select it.
   - After selecting a card, if it's a Realtek chip, you'll see its details in the new menu (such as **ALC897**, **ALC1220**, etc.). This confirms that you have selected the correct Realtek sound card.

   If the selected card is not a Realtek chip, you may need to check the system's audio hardware to ensure the correct card is selected.

   **Here’s a tutorial showing how to disable Auto-Mute:**

   ![Disable Auto-Mute](res/disableAutomute.gif)

5. **Disable Auto-Mute:**
   Using the arrow keys, navigate to the **Auto-Mute** option on the right side and disable it by pressing the `UP/DOWN` arrow keys. Press `ESC` to exit `alsamixer`.

6. **Install hda-verb (if not already installed):**
   You need to install `hda-verb` to run specific commands. Install it using the following commands:

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
   These commands modify audio configurations:
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

## Tools Used

### 1. **Git**
   Git is used to clone the repository onto your system. This allows you to download the necessary scripts and files directly from the source repository.

   **Command:**
   ```bash
   git clone https://github.com/hello2himel/linux-audio-fix.git
   ```

### 2. **chmod**
   The `chmod` command is used to change the permissions of the `AudioFix.sh` script, allowing it to be executed.

   **Command:**
   ```bash
   chmod +x AudioFix.sh
   ```

### 3. **alsamixer**
   `alsamixer` is a terminal-based utility to control the volume and settings of your sound card on Linux. We use it to disable the auto-mute function, which is known to cause audio issues with some Realtek sound chips.

   **Command:**
   ```bash
   alsamixer
   ```

### 4. **hda-verb**
   `hda-verb` is a tool used to send specific commands to the audio hardware via the `hda` driver. It helps in fine-tuning the audio driver settings, which can help resolve issues like no sound or mic problems.

   **Commands:**
   ```bash
   sudo hda-verb /dev/snd/hwC0D0 0x20 0x500 0x1b
   sudo hda-verb /dev/snd/hwC0D0 0x20 0x477 0x4a4b
   sudo hda-verb /dev/snd/hwC0D0 0x20 0x500 0xf
   sudo hda-verb /dev/snd/hwC0D0 0x20 0x477 0x74
   ```

---

## FAQ

### 1. **Why should I update my motherboard BIOS?**
   Updating your motherboard BIOS can fix compatibility issues with various hardware, including sound cards. A new BIOS version may have improvements or fixes related to your Realtek sound card.

### 2. **What if `alsamixer` does not detect my sound card?**
   If `alsamixer` doesn't detect your sound card, ensure that `alsa-utils` is properly installed. You can try reinstalling it.
### 3. **What if the automated script does not work?**
   If the automated script does not fix the issue, try following the manual method. The manual method involves more direct control over your system's audio settings, including disabling auto-mute and running `hda-verb` commands.

### 4. **Do I need to run `hda-verb` commands every time I reboot?**
   No, after successfully running the `hda-verb` commands and rebooting your system, the changes should persist. You shouldn't need to run them again unless there's a system update or other issue that causes the settings to reset.

### 5. **Can I use this fix on any Linux distribution?**
   Yes, this fix should work on most Linux distributions that use the ALSA sound system, such as Ubuntu, Fedora, and Arch Linux. You may need to adjust some commands depending on your distro's package manager.

---

## Conclusion

If the automated method doesn't work for you, follow the manual steps to resolve the issue. By disabling auto-mute and running `hda-verb` commands, you should be able to fix the Realtek audio driver issue on Linux.

---