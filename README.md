# Linux Audio Fix
By following this tutorial, you will be able to fix the issue of Realtek Audio Drivers in Linux.
1. Update your Motherboard **BIOS** to the latest version.
2. Open your **Terminal** and type `alsamixer` and then press enter. (If your terminal doesn't detect the command, you have to install **alsa-utils** first.
For Arch based systems, type `sudo pacman -S alsa-utils`   
Other distros like Ubuntu/Fedora come pre-installed with **alsa-utils**
3. After entering `alsamixer`, press `F6` and select the **Realtek** sound card.
4. Using the arrow keys, go to the right side and focus on **Auto-Mute** and **Disable** it by using UP/DOWN arrow keys. Press `ESC` and close the terminal.
5. **Download** the **AudioFix.sh** file given in this repo.
6. Open the **Folder** in **Terminal** and type the following commands.
```
chmod +x AudioFix.sh
```
```  
./AudioFix.sh
```
8. If you don't have **hda-verb** installed, install it first. Open another terminal window and type:   
Debian/Ubuntu/Raspbian/Kali Linux `apt-get install alsa-tools`   
Arch Linux `pacman -S alsa-tools`   
Fedora `dnf install alsa-tools`   
**Then, run the command again.**
9. Reboot your system.
