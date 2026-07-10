# mykyosinstaller

An installer for arch that is meant to be minimal and reasonably flexible, may include warcrimes in bash scripts.

This project is meant to be my personal installer, and also is meant to teach me bit with git.

# Usage

1.  Boot into a CachyOS live environment. Pure Arch won't work.
2.  Partition your drives manually using a tool like `cfdisk` or `gparted`. This script does not handle partitioning.
    *   **Note on partitioning:** For the boot partition, 80MB is the bare minimum, but 512MB or more is recommended. The script will reformat your chosen root partition, so the filesystem you format it with beforehand doesn't matter. You will be asked if you want to format the boot partition, and it is generally recommended to do so for a clean installation. A separate home partition will only be mounted, not formatted.
3.  Clone this repo:
    ```bash
    git clone --recursive https://github.com/MYKY-open/mykyosinstaller.git
    cd mykyosinstaller
    ```
4.  Run the script:
    ```bash
    sudo ./mykyosinstaller.sh
    ```
5.  Answer the questions. The script will ask you to specify which partitions to use.

# Requirements

pacstrap, filesystem tools.

# Attribution

This project includes [CachyOS-Settings](https://github.com/CachyOS/CachyOS-Settings) 
by the CachyOS team, licensed under GPL-3.

# License

This project is licensed under GPL-3. See LICENSE file for details.
