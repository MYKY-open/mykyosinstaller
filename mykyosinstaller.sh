#!/bin/bash
TCP_CONGESTION_CONTROL=bic
TIMEZONE="Europe/Prague"
LOCALE="en_US.UTF-8"
KEYMAP="cz-qwertz"
SWAPPINESS="100"
KERNEL_PARAMS="zswap.shrinker_enabled=0 mem_sleep_default=deep transparent_hugepage=madvise split_lock_detect=off nowatchdog tsc=reliable clocksource=tsc audit=0 preempt=lazy rcutree.rcu_normal_wake_from_gp=1 mitigations=off random.trust_cpu=on iommu=off"
INSTALL_POINT="/archinstaller"
BTRFS_MOUNT_OPTIONS="autodefrag,noatime,compress=zstd:3,space_cache=v2,ssd,discard=async"
BTRFS_MOUNT_OPTIONS_HDD="autodefrag,noatime,compress=zstd:3,space_cache=v2"

F2FS_MOUNT_OPTIONS="defaults,noatime,lazytime,discard,flush_merge,inline_xattr,inline_data,inline_dentry,mode=adaptive,compress_algorithm=zstd:6,compress_cache"
F2FS_FORMAT_FEATURES="extra_attr,inode_checksum,sb_checksum,compression"
EXT4_MOUNT_OPTIONS="noatime,commit=60,barrier=0"


# Arch Linux Installation Script - Information Gathering
echo "Choose installation mode:"
echo "1) Physical Partitions (Default)"
echo "2) Rootfs Archive (tar.gz)"
read -p "Enter your choice [1-2]: " install_mode_choice

if [[ "$install_mode_choice" == "2" ]]; then
    INSTALL_MODE="archive"
    read -p "Enter the output path for the rootfs archive (e.g., /rootfs.tar.gz): " archive_output_path
    archive_output_path=${archive_output_path:-/rootfs.tar.gz}
    INSTALL_POINT=$(mktemp -d /tmp/mykyos_rootfs.XXXXXX)
    bootloader="none"
    encryption="no"
    filesystem="none"
    format_choice="1"
else
    INSTALL_MODE="partitions"

    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL

    # Get the boot partition location
    read -p "Enter the boot partition location (e.g., /dev/sda1): " boot_partition

    # Get the root partition location
    read -p "Enter the root partition location (e.g., /dev/sda2): " root_partition

    read -p "Enter the home partition location (mount only, partition wont be formatted, mount only)(empty for no separate home): " home_partition

    read -p "Enter the boot partition mountpoint (leave empty for default, default /boot): " bootmountpoint

    echo "Do you want to format boot partition?"
    echo "1) No"
    echo "2) Yes"
    read -p "Enter your choice [1-2]: " format_choice
fi

# Get the desired desktop environment (e.g., gnome, kde, xfce4)
read -p "Enter the desired desktop environment(in terms of package count gnome>kde>mate>xfce>lxqt>none>mini>pico: " desktop_environment

read -p "Enter additional packages: " adpackages

read -p "Enter desired hostname: " HOSTNAME
CRYPTROOT_NAME=$HOSTNAME

# Get the username for the new user
read -p "Enter the username for the new user: " username

# Get the user password (masked input)
read -s -p "Enter the user password: " user_password
echo  # Add a newline after the masked input

# Get the root password (masked input)
read -s -p "Enter the root password: " root_password
echo  # Add a newline after the masked input

# Pacman Config Selection
/lib/ld-linux-x86-64.so.2 --help | grep supported
echo ""
echo "Which pacman configuration would you like to use?"
echo "1. Local config"
echo "2. local cache"
echo "3. Local cache and config"
echo "4. vanilla.conf"
echo "5. cachyV2.conf"
echo "6. cachyV3.conf"
echo "7. cachyV4.conf"
read -p "Enter your choice (1-7): " pacman_config_choice

# Determine pacman config
case $pacman_config_choice in
  1) pacman_config="-P" ;;
  2) pacman_config="-c" ;;
  3) pacman_config="-P -c" ;;
  4) pacman_config="-C ./pacmanconf/vanilla.conf" ;;
  5) pacman_config="-C ./pacmanconf/cachyV2.conf" ;;
  6) pacman_config="-C ./pacmanconf/cachyV3.conf" ;;
  7) pacman_config="-C ./pacmanconf/cachyV4.conf" ;;
  *)
    echo "Invalid choice. Using default pacman configuration."
    pacman_config=""
    ;;
esac

# Kernel Selection
echo ""
echo "Choose a kernel:"
echo "1. linux-cachyos"
echo "2. linux-zen"
echo "3. linux-cachyos-bore"
echo "4. linux-cachyos-bore-lto (V3 or above required, may not play nice with zen cpus, use bore in that case.)"
read -p "Enter the number of your chosen kernel: " kernel_choice

# Determine the kernel package name based on user choice
case $kernel_choice in
  1) kernel_package="linux-cachyos" ;;
  2) kernel_package="linux-zen" ;;
  3) kernel_package="linux-cachyos-bore" ;;
  4) kernel_package="linux-cachyos-bore-lto" ;;
  *)
    echo "Invalid kernel choice.  Defaulting to linux."
    kernel_package="linux"
    ;;
esac

if [[ "$INSTALL_MODE" != "archive" ]]; then
    # Filesystem Selection
    echo ""
    echo "Choose a filesystem:"
    echo "1. ext4 (the universal, recommended)"
    echo "2. btrfs (terminator, cant kill)"
    echo "3. f2fs (flash memory optimized, recommended)"
    read -p "Enter the number of your chosen filesystem: " filesystem_choice

    # Determine the filesystem based on user choice
    case $filesystem_choice in
      1) filesystem="ext4" ;;
      2) filesystem="btrfs" ;;
      3) filesystem="f2fs" ;;
      *)
        echo "Invalid filesystem choice. Defaulting to ext4."
        filesystem="ext4"
        ;;
    esac

    if [[ "$filesystem" == "btrfs" ]]; then
        echo ""
        echo "Is the target disk an HDD or SSD?"
        echo "1. SSD / NVMe (enables ssd mode, async discard)"
        echo "2. HDD        (no ssd mode, no discard, autodefrag)"
        read -p "Enter your choice (1 or 2): " btrfs_disk_type
        if [[ "$btrfs_disk_type" == "2" ]]; then
            BTRFS_MOUNT_OPTIONS="$BTRFS_MOUNT_OPTIONS_HDD"
        fi
    fi

    if [[ "$filesystem" == "f2fs" ]]; then
        KERNEL_PARAMS="$KERNEL_PARAMS rootflags=atgc,gc_merge,noatime,compress_algorithm=zstd:6,compress_cache"
    fi

    if [[ "$filesystem" == "ext4" ]]; then
        KERNEL_PARAMS="$KERNEL_PARAMS rootflags=noatime,lazytime,discard,commit=60,dioread_nolock"
    fi
fi

if [[ "$INSTALL_MODE" != "archive" ]]; then
    # Encryption Selection
    echo ""
    echo "Do you want to encrypt the root partition?"
    echo "1. No"
    echo "2. Yes (using LUKS)"
    read -p "Enter your choice (1 or 2): " encryption_choice
fi

# Zram Selection
echo ""
echo "Enable zram swap? (compressed RAM-backed swap, good for low-RAM systems)"
echo "1. No"
echo "2. Yes"
read -p "Enter your choice (1 or 2): " zram_choice

# Determine encryption status
case $format_choice in
  1) format_boot_partition="no" ;;
  2) format_boot_partition="yes" ;;
  *)
    echo "Invalid choice. Defaulting to no format."
    format_boot_partition="no"
    ;;
esac

# Determine encryption status
case $encryption_choice in
  1) encryption="no" ;;
  2) encryption="yes" ;;
  *)
    echo "Invalid choice. Defaulting to no encryption."
    encryption="no"
    ;;
esac

# Determine zram status
case $zram_choice in
  1) enable_zram="no" ;;
  2) enable_zram="yes" ;;
  *)
    echo "Invalid choice. Defaulting to no zram."
    enable_zram="no"
    ;;
esac

if [[ "$encryption" == "yes" ]]; then
    KERNEL_PARAMS="$KERNEL_PARAMS rd.luks.options=discard"
fi

if [[ "$INSTALL_MODE" != "archive" ]]; then
    # Bootloader Selection
    echo ""
    echo "Choose a bootloader:"
    echo "1. systemd-boot (simpler, faster)"
    echo "2. GRUB efi (more features, supports multiple OSes)"
    echo "3. GRUB efi 32bit (more features, supports multiple OSes, for cursed 32bit efi computers with 64bit cpus, like intel atom netbooks)"
    echo "4. GRUB bios (more features, supports multiple OSes)"
    read -p "Enter the number of your chosen bootloader (1-4): " bootloader_choice

    # Determine bootloader type
    case $bootloader_choice in
      1) bootloader="systemd-boot" ;;
      2) bootloader="grub" ;;
      3) bootloader="grub32bitefi" ;;
      4) bootloader="grub-bios" ;;
      *)
        echo "Invalid choice. Defaulting to systemd-boot."
        bootloader="systemd-boot"
        ;;
    esac

    if [[ "$bootloader" == "grub" || "$bootloader" == "grub32bitefi" ]]; then
        echo "GRUB bootloader detected. Choose installation mode:"
        echo "1) Install with --removable flag"
        echo "2) Install normally (no --removable)"

        read -rp "Enter your choice [1-2]: " choice
        case "$choice" in
            1)
                grubstate="--removable"
                ;;
            2)
                grubstate=""
                ;;
            *)
                echo "Invalid choice. Defaulting to normal installation."
                grubstate=""
                ;;
        esac
    fi
fi

# Confirm the information
echo ""
echo "Let's review the gathered information:"
echo "Installation Mode: $INSTALL_MODE"
if [[ "$INSTALL_MODE" == "archive" ]]; then
    echo "Archive Output Path: $archive_output_path"
else
    echo "Boot Partition: $boot_partition"
    echo "Format boot: $format_choice"
    echo "Root Partition: $root_partition"
    echo "Home partition override: $home_partition"
    echo "Filesystem: $filesystem"
    echo "Encryption: $encryption"
    echo "Bootloader: $bootloader"
    echo "Grub Removeable state: $grubstate"
fi
echo "Desktop Environment: $desktop_environment"
echo "Hostname: $HOSTNAME"
echo "Username: $username"
echo "Kernel: $kernel_package"
echo "Pacman Config: ${pacman_config:-(default)}"
echo ""
if [[ "$INSTALL_MODE" != "archive" ]]; then
    echo "you may still enable swap partition at this time, it will be written to fstab, also you may wanna check out fstab before reboot, it sometimes screws up."
    echo ""
    read -p "Proceed with installation? This will format partitions. (y/N): " confirm
else
    read -p "Proceed with generating rootfs archive? (y/N): " confirm
fi
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

source ./archinstallfunctions.sh

if [[ "$INSTALL_MODE" != "archive" ]]; then
    format_partitions
    mount_partitions
    mount_home
else
    mkdir -p "$INSTALL_POINT"
fi

install_base_system
chroot_into_system
install_configs
if [[ "$enable_zram" == "yes" ]]; then
    configure_zram
fi

if [[ "$INSTALL_MODE" != "archive" ]]; then
    if [ "$bootloader" = "grub" ]; then
        install_grub
    elif [ "$bootloader" = "grub32bitefi" ]; then
        install_grubcursed
    elif [ "$bootloader" = "grub-bios" ]; then
        install_grub_bios
    else
        sysdboot
    fi

    sync
    echo drive write is synced, it may be safe to remove now but its still recommended to unmount, but not required. use this time to check fstab for errors.
else
    create_rootfs_archive
    echo "Archive generation complete at $archive_output_path."
    # Clean up the temporary directory
    rm -rf "$INSTALL_POINT"
fi
