print_step() {
    local message="$1"
    echo -e "\n\033[1;32m=> $message\033[0m"
}

install_configs() {
    print_step "Installing system configurations..."
    # Copy system-wide configurations
    if [[ -d "./cachyos-settings" ]]; then
        # Only copy directories from CachyOS-Settings, ignore root-level files
        for item in ./cachyos-settings/*/; do
            if [[ -d "$item" ]]; then
                # Get the directory name without the path
                dirname=$(basename "$item")
                echo "Copying directory: $dirname"
                cp -r "$item" "$INSTALL_POINT/"
            fi
        done
    else
        echo "Warning: CachyOS-Settings directory not found, skipping system configs"
    fi

    # Ensure systemd-resolved Quad9 DoT configuration exists
    if [[ ! -f "$INSTALL_POINT/usr/lib/systemd/resolved.conf.d/10-quad9.conf" && ! -f "$INSTALL_POINT/etc/systemd/resolved.conf.d/10-quad9.conf" ]]; then
        mkdir -p "$INSTALL_POINT/etc/systemd/resolved.conf.d"
        cat > "$INSTALL_POINT/etc/systemd/resolved.conf.d/10-quad9.conf" <<'QUAD9_EOF'
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net
FallbackDNS=149.112.112.112#dns.quad9.net 2620:fe::9#dns.quad9.net 9.9.9.9#dns.quad9.net 2620:fe::fe#dns.quad9.net
DNSOverTLS=yes
Domains=~.
QUAD9_EOF
    fi

    # Ensure NetworkManager delegates DNS to systemd-resolved
    if [[ ! -f "$INSTALL_POINT/usr/lib/NetworkManager/conf.d/dns.conf" && ! -f "$INSTALL_POINT/etc/NetworkManager/conf.d/dns.conf" ]]; then
        mkdir -p "$INSTALL_POINT/etc/NetworkManager/conf.d"
        cat > "$INSTALL_POINT/etc/NetworkManager/conf.d/dns.conf" <<'NM_DNS_EOF'
[main]
dns=systemd-resolved
NM_DNS_EOF
    fi


    # Copy user-specific configurations
    if [[ -d "./home" ]]; then
        print_step "Installing user configurations for $username..."
        # Ensure the user's home directory exists
        mkdir -p "$INSTALL_POINT/home/$username"
        # Copy the files
        rsync -a ./home/ "$INSTALL_POINT/home/$username/"
        # Fix ownership of the copied files
        arch-chroot "$INSTALL_POINT" chown -R "$username:$username" "/home/$username"
    else
        echo "Warning: ./home directory not found, skipping user configs"
    fi
}

mount_home() {
    # Only proceed if home_partition is defined
    if [[ -z "$home_partition" ]]; then
        echo "Skipping home mount: \$home_partition is not set."
        return 0
    fi

    # Define target mount point
    local target="$INSTALL_POINT/home"

    print_step "Mounting home partition $home_partition to $target..."
    mkdir -p "$target"

    # Detect filesystem type
    local fstype
    fstype=$(blkid -s TYPE -o value "$home_partition") || {
        echo "Error: could not detect filesystem type of $home_partition"
        return 1
    }

    # Choose mount options based on fs type
    local opts
    case "$fstype" in
        btrfs)
            opts=$BTRFS_MOUNT_OPTIONS
            ;;

        f2fs)
            opts=$F2FS_MOUNT_OPTIONS
            ;;
        ext4)
            opts=$EXT4_MOUNT_OPTIONS
            ;;
        *)
            echo "Warning: unknown fs type '$fstype' – mounting without extra options."
            opts=""
            ;;
    esac

    # Perform the mount
    if [[ -n "$opts" ]]; then
        mount -o "$opts" "$home_partition" "$target"
    else
        mount "$home_partition" "$target"
    fi

    # Check mount success
    if mountpoint -q "$target"; then
        echo "Home partition mounted successfully."
    else
        echo "Error: failed to mount $home_partition on $target"
        return 1
    fi
}

format_partitions() {
    # Optionally format the boot partition based on variable
    if [[ "$format_boot_partition" == "yes" ]]; then
        print_step "Formatting boot partition $boot_partition as FAT32..."
        mkfs.fat -F32 "$boot_partition"
    else
        echo "Skipping formatting of $boot_partition."
    fi

    # Handle root partition formatting based on encryption setting
    if [[ "$encryption" == "yes" ]]; then
        print_step "Encrypting root partition $root_partition with LUKS..."
        cryptsetup luksFormat "$root_partition"
        cryptsetup open "$root_partition" "$CRYPTROOT_NAME"
        root_device="/dev/mapper/$CRYPTROOT_NAME"
    else
        root_device="$root_partition"
    fi

    # Format root partition based on selected filesystem
    case "$filesystem" in
        "ext4")
            print_step "Formatting root partition $root_device as ext4..."
            mkfs.ext4 "$root_device"
            ;;
        "btrfs")
            print_step "Formatting root partition $root_device as btrfs..."
            mkfs.btrfs -f "$root_device"
            ;;
        "f2fs")
            print_step "Formatting root partition $root_device as f2fs with options $F2FS_FORMAT_FEATURES..."
            mkfs.f2fs -f -O "$F2FS_FORMAT_FEATURES" "$root_device"
            ;;

        *)
            echo "Invalid filesystem choice. Defaulting to ext4."
            mkfs.ext4 "$root_device"
            ;;
    esac
}


mount_partitions() {
    # Mount the root partition
    bootmountpoint=${bootmountpoint:-/boot}
    print_step "Mounting root partition $root_device to $INSTALL_POINT..."
    mkdir -p $INSTALL_POINT
    case $filesystem in
        "ext4")
            mount -o $EXT4_MOUNT_OPTIONS $root_device $INSTALL_POINT
            ;;
        "btrfs")
            mount -o $BTRFS_MOUNT_OPTIONS $root_device $INSTALL_POINT
            ;;
        "f2fs")
            mount -o $F2FS_MOUNT_OPTIONS $root_device $INSTALL_POINT
            ;;

        *)
            mount -o $EXT4_MOUNT_OPTIONS $root_device $INSTALL_POINT
            ;;
    esac

    # Mount the boot partition
    print_step "Mounting boot partition $boot_partition to $INSTALL_POINT$bootmountpoint..."
    mkdir -p $INSTALL_POINT$bootmountpoint
    mount $boot_partition $INSTALL_POINT$bootmountpoint
}

install_base_system() {
    # Determine which mesa package to use
    local mesa_pkg="mesa"
    if [[ "$pacman_config" == *"V3"* ]] || [[ "$pacman_config" == *"V4"* ]]; then
        mesa_pkg="mesa-git"
    fi

    # Base packages including the chosen kernel and base-devel
    base_packages="base base-devel dhcpcd $kernel_package power-profiles-daemon pacman nano git sudo linux-firmware wireless-regdb efibootmgr networkmanager bluez bluez-utils htop fastfetch wireplumber git mkinitcpio reflector zsh zsh-theme-powerlevel10k cachyos-rate-mirrors $mesa_pkg"

    # Additional packages based on the chosen filesystem
    case $filesystem in
        "btrfs")
            base_packages="$base_packages btrfs-progs"
            ;;
        "f2fs")
            base_packages="$base_packages f2fs-tools"
            ;;

    esac

    # Desktop environment packages
    case $desktop_environment in
        "gnome")
            base_packages="$base_packages sddm gnome $adpackages"
            ;;
        "kde")
            base_packages="$base_packages sddm xorg wayland plasma sddm konsole dolphin ark $adpackages"
            ;;
        "xfce")
            base_packages="$base_packages sddm xfce4 $adpackages"
            ;;
        "mate")
            base_packages="$base_packages sddm mate $adpackages"
            ;;
        "mini")
            base_packages="cachyos-rate-mirrors base dhcpcd networkmanager sudo mkinitcpio $kernel_package"
            ;;
        "lxqt")
            base_packages="$base_packages sddm lxqt xorg $adpackages"
            ;;
        "pico")
            base_packages="cachyos-rate-mirrors mkinitcpio $adpackages $kernel_package"
            ;;
        *)
            echo "No valid desktop environment selected. Only base system will be installed."
            ;;
    esac

    # Use pacstrap to install the base system and additional packages
    print_step "Installing base system and additional packages with pacstrap..."
    pacstrap -P $pacman_config $INSTALL_POINT $base_packages
}

chroot_into_system() {
    # Generate fstab
    if [[ "$INSTALL_MODE" != "archive" ]]; then
        print_step "Generating fstab..."
        genfstab -U $INSTALL_POINT >> $INSTALL_POINT/etc/fstab
    else
        print_step "Skipping fstab generation for archive mode..."
    fi

    # Chroot into the new system and execute commands
    print_step "Chrooting into the new system at $INSTALL_POINT..."
    arch-chroot $INSTALL_POINT /bin/bash <<EOF
# Basic setup
print_step "Setting up timezone and clock..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOL

# setup locales and console keymap
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Uncomment the locale dynamically using the variable
sed -i "s/^#$LOCALE UTF-8/$LOCALE UTF-8/" /etc/locale.gen

# Generate it
locale-gen

# Set the persistent configuration
echo "LANG=$LOCALE" > /etc/locale.conf

# Initramfs configuration
print_step "Configuring initramfs..."
if [ "$encryption" = yes ]; then
    if [ "$filesystem" = "btrfs" ]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard keymap modconf block sd-encrypt btrfs filesystems fsck autodetect microcode)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf

    elif [ "$filesystem" = "f2fs" ]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard keymap modconf block sd-encrypt filesystems fsck autodetect microcode)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(f2fs)/' /etc/mkinitcpio.conf
    elif [ "$filesystem" = "ext4" ]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard keymap modconf block sd-encrypt filesystems fsck autodetect microcode)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(ext4)/' /etc/mkinitcpio.conf
    fi
else
    if [ "$filesystem" = "btrfs" ]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard keymap modconf block btrfs filesystems fsck autodetect microcode)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf

    elif [ "$filesystem" = "f2fs" ]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard keymap modconf block filesystems fsck autodetect microcode)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(f2fs)/' /etc/mkinitcpio.conf
    elif [ "$filesystem" = "ext4" ]; then
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard keymap modconf block filesystems fsck autodetect microcode)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(ext4)/' /etc/mkinitcpio.conf
    fi
fi
mkinitcpio -P

# Set root password
echo "Setting root password..."
echo "root:$root_password" | chpasswd

# Create user account and set password
echo "Creating user $username..."
useradd -m -G wheel -s /bin/zsh $username
echo "Setting password for $username..."
echo "$username:$user_password" | chpasswd

# Configure sudo for the wheel group
echo "Configuring sudo for the wheel group..."
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Enable services
print_step "Enabling services..."
systemctl enable NetworkManager
systemctl enable systemd-resolved
systemctl enable fstrim.timer
systemctl enable reflector.timer
systemctl enable power-profiles-daemon.service
systemctl enable sddm
# Ensure dhcpcd and systemd-networkd do not clash with NetworkManager
systemctl disable dhcpcd 2>/dev/null || true
systemctl disable systemd-networkd 2>/dev/null || true
systemctl disable iwd 2>/dev/null || true

# Performance tuning
print_step "Applying performance tweaks..."
cat << SYSCTL > /etc/sysctl.d/99-performance.conf
# improvements
vm.swappiness = $SWAPPINESS
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
kernel.split_lock_mitigate=0

# Optimization: Reduce VM statistic update frequency
vm.stat_interval = 60

# Optimization: Restrict perf event monitoring
kernel.perf_event_paranoid = 3

# Network improvements
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.core.optmem_max = 65536
net.ipv4.tcp_congestion_control = $TCP_CONGESTION_CONTROL
net.core.default_qdisc = cake
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1

# Sched bias to throughput and efficiency
kernel.sched_util_clamp_min = 0
kernel.sched_cfs_bandwidth_slice_us = 50000

# File system and app improvements
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
SYSCTL

# TCP Algorithm Deep Tuning (Final Boss Settings)
print_step "Applying TCP module deep tuning..."
mkdir -p /etc/modprobe.d
echo "options tcp_bic fast_convergence=0 beta=700 max_increment=64" > /etc/modprobe.d/tcp_bic.conf

# Set up zsh for the user
print_step "Setting up user environment..."
mkdir -p /home/$username/.config
echo "source /usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme" >> /home/$username/.zshrc
cat << ZSHRC >> /home/$username/.zshrc
# Basic zsh configuration
setopt autocd
setopt interactive_comments
setopt extended_glob

# History settings
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory
setopt hist_ignore_all_dups
setopt hist_ignore_space

# Basic completions
autoload -Uz compinit
compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# Key bindings
bindkey -e  # Use emacs key bindings
bindkey '^[[H' beginning-of-line                 # Home key
bindkey '^[[F' end-of-line                       # End key
bindkey '^[[3~' delete-char                      # Delete key
bindkey '^[[A' history-beginning-search-backward # Up arrow
bindkey '^[[B' history-beginning-search-forward  # Down arrow

# Aliases
alias ls='ls --color=auto'
alias ll='ls -la'
alias grep='grep --color=auto'
alias ip='ip -color=auto'
# alias sudo='sudo-rs'
# compdef sudo-rs=sudo

# Add colors to man pages
export LESS_TERMCAP_mb=$'\e[1;32m'
export LESS_TERMCAP_md=$'\e[1;32m'
export LESS_TERMCAP_me=$'\e[0m'
export LESS_TERMCAP_se=$'\e[0m'
export LESS_TERMCAP_so=$'\e[01;33m'
export LESS_TERMCAP_ue=$'\e[0m'
export LESS_TERMCAP_us=$'\e[1;4;31m'
ZSHRC

# Give user.slice higher CPU and IO weight so userspace beats kernel/system tasks
mkdir -p /etc/systemd/system/user.slice.d
cat > /etc/systemd/system/user.slice.d/99-resources.conf <<EOL
[Slice]
CPUWeight=800
IOWeight=800
EOL

# Fix ownership of user home directory and files
echo "Fixing ownership of user home directory..."
chown -R $username:$username /home/$username

# Enable periodic TRIM for SSDs
print_step "Setting up SSD TRIM..."
systemctl enable fstrim.timer

localectl set-keymap $KEYMAP
journalctl --vacuum-size=100M
touch /etc/pacman.d/cachyos-mirrorlist
touch /etc/pacman.d/cachyos-v3-mirrorlist
touch /etc/pacman.d/cachyos-v4-mirrorlist
cachyos-rate-mirrors
chmod 644 /etc/pacman.conf
systemctl mask systemd-coredump.service
systemctl mask systemd-coredump.socket
EOF
    # Set up resolv.conf symlink on target filesystem outside the chroot (avoids arch-chroot bind-mount collision)
    ln -sf /run/systemd/resolve/stub-resolv.conf "$INSTALL_POINT/etc/resolv.conf"
}

configure_zram() {
    print_step "Enabling zram swap..."
    mkdir -p "$INSTALL_POINT/usr/lib/systemd"
    cat > "$INSTALL_POINT/usr/lib/systemd/zram-generator.conf" <<EOL
[zram0]
compression-algorithm = zstd
zram-size = ram
swap-priority = 100
fs-type = swap
EOL
}

sysdboot() {
    # Pre-resolve identifiers based on encryption (matching GRUB pattern)
    local luks_uuid=""
    local root_partuuid=""
    if [ "$encryption" = "yes" ]; then
        luks_uuid=$(blkid -s UUID -o value "$root_partition")
        if [ -z "$luks_uuid" ]; then
            echo "Error: could not determine UUID of LUKS container $root_partition"
            return 1
        fi
    else
        root_partuuid=$(blkid -s PARTUUID -o value "$root_device")
        if [ -z "$root_partuuid" ]; then
            echo "Error: could not determine PARTUUID of $root_device"
            return 1
        fi
    fi
    arch-chroot "$INSTALL_POINT" /bin/bash <<EOF
# Bootloader
print_step "Installing bootloader..."
bootctl install

# Create boot entry
mkdir -p /boot/loader/entries
if [ "$encryption" = "yes" ]; then
    LUKS_UUID="$luks_uuid"
    cat << EOL > /boot/loader/entries/arch.conf
title   MYKYcorp ($kernel_package)
linux   /vmlinuz-$kernel_package
initrd  /initramfs-$kernel_package.img
options rd.luks.uuid=\$LUKS_UUID rd.luks.name=\$LUKS_UUID=$CRYPTROOT_NAME root=/dev/mapper/$CRYPTROOT_NAME rw $KERNEL_PARAMS
EOL
else
    ROOT_PARTUUID="$root_partuuid"
    cat << EOL > /boot/loader/entries/arch.conf
title   MYKYcorp ($kernel_package)
linux   /vmlinuz-$kernel_package
initrd  /initramfs-$kernel_package.img
options root=PARTUUID=\$ROOT_PARTUUID rw $KERNEL_PARAMS
EOL
fi

cat > /boot/loader/loader.conf <<EOL
timeout 0
console-mode max
editor yes
default @saved
EOL
EOF
}

install_grub() {
    # Pre‑resolve identifiers based on encryption
    local luks_uuid=""
    local root_partuuid=""
    if [ "$encryption" = "yes" ]; then
        luks_uuid=$(blkid -s UUID -o value "$root_partition")
        if [ -z "$luks_uuid" ]; then
            echo "Error: could not determine UUID of LUKS container $root_partition"
            return 1
        fi
    else
        root_partuuid=$(blkid -s PARTUUID -o value "$root_device")
        if [ -z "$root_partuuid" ]; then
            echo "Error: could not determine PARTUUID of $root_device"
            return 1
        fi
    fi
    arch-chroot "$INSTALL_POINT" /bin/bash <<EOF
    pacman -S --noconfirm grub efibootmgr os-prober
    if [ "$encryption" = "yes" ]; then
        # Pass the UUID variable into the environment for encrypted systems
        LUKS_UUID="$luks_uuid"
        # Use systemd-based encryption parameter syntax for sd-encrypt hook
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=/dev/mapper/${CRYPTROOT_NAME} rd.luks.name=\$LUKS_UUID=${CRYPTROOT_NAME} ${KERNEL_PARAMS}\"|" /etc/default/grub
        sed -i 's|^#GRUB_ENABLE_CRYPTODISK=y|GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub
        # Add cryptodisk modules to preload
        sed -i 's|^GRUB_PRELOAD_MODULES=.*|GRUB_PRELOAD_MODULES="part_gpt part_msdos luks cryptodisk"|' /etc/default/grub
    else
        # For unencrypted systems, use PARTUUID
        ROOT_PARTUUID="$root_partuuid"
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=PARTUUID=\$ROOT_PARTUUID ${KERNEL_PARAMS}\"|" /etc/default/grub
    fi
    sed -i 's|^#GRUB_TIMEOUT=[0-9]\+|GRUB_TIMEOUT=3|' /etc/default/grub
    sed -i 's|^#GRUB_DISABLE_OS_PROBER=false|GRUB_DISABLE_OS_PROBER=false|' /etc/default/grub
    sed -i 's|^GRUB_TIMEOUT_STYLE=hidden|#GRUB_TIMEOUT_STYLE=hidden|' /etc/default/grub
    grub-install \
      --target=x86_64-efi \
      --efi-directory=/boot \
      --bootloader-id=MYKYcorp_GRUB \
      --recheck $grubstate
    grub-mkconfig -o /boot/grub/grub.cfg
    chmod -R g-rwx,o-rwx /boot/efi
EOF
}

install_grubcursed() {
    # For devices with 32-bit UEFI but 64-bit CPU
    local luks_uuid=""
    local root_partuuid=""
    if [ "$encryption" = "yes" ]; then
        luks_uuid=$(blkid -s UUID -o value "$root_partition")
        if [ -z "$luks_uuid" ]; then
            echo "Error: could not determine UUID of LUKS container $root_partition"
            return 1
        fi
    else
        root_partuuid=$(blkid -s PARTUUID -o value "$root_device")
        if [ -z "$root_partuuid" ]; then
            echo "Error: could not determine PARTUUID of $root_device"
            return 1
        fi
    fi
    arch-chroot "$INSTALL_POINT" /bin/bash <<EOF
    pacman -S --noconfirm grub efibootmgr os-prober
    if [ "$encryption" = "yes" ]; then
        # Pass the UUID variable into the environment for encrypted systems
        LUKS_UUID="$luks_uuid"
        # Use systemd-based encryption parameter syntax for sd-encrypt hook
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=/dev/mapper/${CRYPTROOT_NAME} rd.luks.name=\$LUKS_UUID=${CRYPTROOT_NAME} ${KERNEL_PARAMS}\"|" /etc/default/grub
        sed -i 's|^#GRUB_ENABLE_CRYPTODISK=y|GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub
        # Add cryptodisk modules to preload
        sed -i 's|^GRUB_PRELOAD_MODULES=.*|GRUB_PRELOAD_MODULES="part_gpt part_msdos luks cryptodisk"|' /etc/default/grub
    else
        # For unencrypted systems, use PARTUUID
        ROOT_PARTUUID="$root_partuuid"
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=PARTUUID=\$ROOT_PARTUUID ${KERNEL_PARAMS}\"|" /etc/default/grub
    fi
    sed -i 's|^#GRUB_TIMEOUT=[0-9]\+|GRUB_TIMEOUT=3|' /etc/default/grub
    sed -i 's|^#GRUB_DISABLE_OS_PROBER=false|GRUB_DISABLE_OS_PROBER=false|' /etc/default/grub
    sed -i 's|^GRUB_TIMEOUT_STYLE=hidden|#GRUB_TIMEOUT_STYLE=hidden|' /etc/default/grub
    grub-install \
      --target=i386-efi \
      --efi-directory=/boot \
      --bootloader-id=MYKYcorp_GRUB \
      --recheck $grubstate
    grub-mkconfig -o /boot/grub/grub.cfg
    chmod -R g-rwx,o-rwx /boot/efi
EOF
}

install_grub_bios() {
    # Pre-resolve identifiers and disk device
    local luks_uuid=""
    local root_partuuid=""
    local disk=""
    if [ "$encryption" = "yes" ]; then
        luks_uuid=$(blkid -s UUID -o value "$root_partition")
        if [ -z "$luks_uuid" ]; then
            echo "Error: could not determine UUID of LUKS container $root_partition"
            return 1
        fi
    else
        root_partuuid=$(blkid -s PARTUUID -o value "$root_device")
        if [ -z "$root_partuuid" ]; then
            echo "Error: could not determine PARTUUID of $root_device"
            return 1
        fi
    fi
    # Strip partition number to get disk (e.g. /dev/sda2 -> /dev/sda)
    disk=$(echo "$root_partition" | sed 's/[0-9]*$//')
    arch-chroot "$INSTALL_POINT" /bin/bash <<EOF
    # Install GRUB and required packages
    print_step "Installing GRUB bootloader for BIOS system..."
    pacman -S --noconfirm grub os-prober
    # Configure GRUB
    if [ "$encryption" = "yes" ]; then
        # Pass the UUID variable into the environment for encrypted systems
        LUKS_UUID="$luks_uuid"
        # Use systemd-based encryption parameter syntax for sd-encrypt hook
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=/dev/mapper/${CRYPTROOT_NAME} rd.luks.name=\$LUKS_UUID=${CRYPTROOT_NAME} ${KERNEL_PARAMS}\"|" /etc/default/grub
        sed -i 's|^#GRUB_ENABLE_CRYPTODISK=y|GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub
        # Add cryptodisk modules to preload
        sed -i 's|^GRUB_PRELOAD_MODULES=.*|GRUB_PRELOAD_MODULES="part_gpt part_msdos luks cryptodisk"|' /etc/default/grub
    else
        # For unencrypted systems, use PARTUUID
        ROOT_PARTUUID="$root_partuuid"
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=PARTUUID=\$ROOT_PARTUUID ${KERNEL_PARAMS}\"|" /etc/default/grub
    fi
    # Theme and timing tweaks
    sed -i 's|^#GRUB_TIMEOUT=[0-9]\+|GRUB_TIMEOUT=3|' /etc/default/grub
    sed -i 's|^#GRUB_DISABLE_OS_PROBER=false|GRUB_DISABLE_OS_PROBER=false|' /etc/default/grub
    sed -i 's|^GRUB_TIMEOUT_STYLE=hidden|#GRUB_TIMEOUT_STYLE=hidden|' /etc/default/grub
    # Install GRUB to MBR
    grub-install \
      --target=i386-pc \
      --recheck \
      --boot-directory=/boot \
      ${disk}
    # Generate GRUB configuration
    grub-mkconfig -o /boot/grub/grub.cfg
EOF
}

create_rootfs_archive() {
    print_step "Creating rootfs archive at $archive_output_path..."
    # Ensure the parent directory for the output path exists
    mkdir -p "$(dirname "$archive_output_path")"
    
    # Compress the INSTALL_POINT into the target archive
    # Support common extensions: tar.gz, tar.zst, tar.xz
    if [[ "$archive_output_path" == *.tar.zst ]]; then
        tar --numeric-owner -I 'zstd -T0' -cpf "$archive_output_path" -C "$INSTALL_POINT" .
    elif [[ "$archive_output_path" == *.tar.xz ]]; then
        tar --numeric-owner -I 'xz -T0' -cpf "$archive_output_path" -C "$INSTALL_POINT" .
    else
        # Default to gzip
        tar --numeric-owner -czpf "$archive_output_path" -C "$INSTALL_POINT" .
    fi
}
