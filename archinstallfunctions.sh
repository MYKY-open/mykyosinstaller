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

# ---------------------------------------------------------------------------
# Generic multi-partition support.
# MOUNTS entries are "device|mountpoint|fstype|format(yes/no)|enc(yes/no)"
# and are built by the TUI disk planner in mykyosinstaller.sh.
# fstype "inherit" marks a BIND mount: same filesystem as the device's primary
# assignment, mounted at an additional mountpoint via mount --bind.
# enc "yes" = LUKS2 container. Root is unlocked by initramfs (rd.luks.uuid),
# everything else by systemd crypttab with a keyfile stored on encrypted root.
# ---------------------------------------------------------------------------

prepare_partition() {
    local part="$1"
    # Unmount any stale mounts held on this partition (live env automount, leftovers)
    if findmnt -rn -S "$part" >/dev/null 2>&1; then
        echo "Warning: $part has stale mount(s), unmounting..."
        findmnt -rn -S "$part" -o TARGET -n | while read -r m; do
            umount -R "$m" 2>/dev/null || umount -l "$m"
        done
    fi
    # Wipe old filesystem signatures so kernel/blkid can't mistake the old fs for the valid one
    wipefs -af "$part"
    sync
}

# Deterministic mapper name for a mountpoint: /mnt/data -> crypt-mnt-data
crypt_name() {
    local n="${1#/}"
    echo "crypt-${n//\//-}"
}

# RAID sets: entries are "name|level|dev1 dev2 ..." (built by the planner).
# A MOUNTS entry references an array with device field "md:<name>".
real_dev() {
    if [[ "$1" == md:* ]]; then
        echo "/dev/md/${1#md:}"
    else
        echo "$1"
    fi
}

create_raid_arrays() {
    local set name level members node d
    [[ ${#RAIDSETS[@]} -gt 0 ]] || return 0
    for set in "${RAIDSETS[@]}"; do
        IFS='|' read -r name level members <<<"$set"
        local -a devs
        read -ra devs <<<"$members"
        node="/dev/md/$name"
        if [[ -e "$node" ]]; then
            echo "RAID array $node already exists, reusing it."
            continue
        fi
        print_step "Creating RAID$level array $node (${#devs[@]} disks: ${devs[*]})..."
        # stale md superblocks would block assembly
        for d in "${devs[@]}"; do
            wipefs -af "$d" >/dev/null 2>&1 || true
        done
        mdadm --create "$node" --level="$level" --raid-devices="${#devs[@]}" --run "${devs[@]}"
    done
    udevadm settle
}

# First regular (non-bind, non-swap) mountpoint of a device
primary_of() {
    local want="$1" spec d m f
    for spec in "${MOUNTS[@]}"; do
        IFS='|' read -r d m f _ _ <<<"$spec"
        if [[ "$d" == "$want" && "$f" != "inherit" && "$m" != "swap" ]]; then
            echo "$m"
            return 0
        fi
    done
    return 1
}

mount_opts_for() {
    local fs="$1"
    case "$fs" in
        btrfs) echo "$BTRFS_MOUNT_OPTIONS" ;;
        f2fs)  echo "$F2FS_MOUNT_OPTIONS" ;;
        ext4)  echo "$EXT4_MOUNT_OPTIONS" ;;
        *)     echo "" ;;
    esac
}

format_all() {
    local spec dev mnt fs fmt enc
    create_raid_arrays
    for spec in "${MOUNTS[@]}"; do
        IFS='|' read -r dev mnt fs fmt enc <<<"$spec"
        if [[ "$fs" == "inherit" ]]; then
            echo "$dev bind-> $mnt shares the primary filesystem, nothing to format."
            continue
        fi
        if [[ "$fmt" != "yes" ]]; then
            echo "Skipping format of $dev ($mnt) as requested."
            continue
        fi
        dev=$(real_dev "$dev")
        prepare_partition "$dev"
        if [[ "$mnt" == "/" ]]; then
            root_partition="$dev"
            if [[ "$enc" == "yes" ]]; then
                print_step "Encrypting root partition $dev with LUKS..."
                cryptsetup luksFormat "$dev"
                cryptsetup open "$dev" "$CRYPTROOT_NAME"
                root_device="/dev/mapper/$CRYPTROOT_NAME"
                dev="$root_device"
            else
                root_device="$dev"
            fi
        elif [[ "$enc" == "yes" ]]; then
            # Secondary LUKS container: unlocked at boot via crypttab + keyfile.
            # Keyfile goes to a temp stash - INSTALL_POINT is not the mounted
            # root partition yet, generate_fstab moves it into the target later.
            local cname keyfile
            cname=$(crypt_name "$mnt")
            [[ -n "${KEYFILE_DIR:-}" ]] || KEYFILE_DIR=$(mktemp -d)
            keyfile="$KEYFILE_DIR/$cname.key"
            print_step "Encrypting $dev ($mnt) with LUKS as /dev/mapper/$cname..."
            cryptsetup luksFormat "$dev"
            cryptsetup open "$dev" "$cname"
            dd if=/dev/urandom of="$keyfile" bs=512 count=8
            chmod 600 "$keyfile"
            # luksAddKey prompts for the passphrase just given at luksFormat
            cryptsetup luksAddKey "$dev" "$keyfile"
            dev="/dev/mapper/$cname"
        fi
        case "$fs" in
            ext4)
                print_step "Formatting $dev ($mnt) as ext4..."
                mkfs.ext4 -F "$dev"
                ;;
            btrfs)
                print_step "Formatting $dev ($mnt) as btrfs..."
                mkfs.btrfs -f "$dev"
                ;;
            f2fs)
                print_step "Formatting $dev ($mnt) as f2fs..."
                mkfs.f2fs -f -O "$F2FS_FORMAT_FEATURES" "$dev"
                ;;
            vfat)
                print_step "Formatting $dev ($mnt) as FAT32..."
                mkfs.fat -F32 "$dev"
                ;;
            swap)
                print_step "Setting up swap on $dev..."
                mkswap -L mykyswap "$dev"
                ;;
            *)
                echo "Error: unknown filesystem '$fs' for $dev, skipping format."
                ;;
        esac
    done
    # Make sure all format writes hit the disk and udev re-scanned before mount
    sync
    udevadm settle
}

mount_one() {
    local dev="$1" mnt="$2" fs="$3"
    local target="$INSTALL_POINT$mnt"
    mkdir -p "$target"
    if [[ "$fs" == "inherit" ]]; then
        # Bind mount of a SUBDIRECTORY of the device's primary (container) mountpoint.
        # Subdir name = mountpoint path without leading slash: /var -> var,
        # /srv/docker -> srv/docker. Keeps each target's content isolated on the
        # shared filesystem instead of aliasing the whole fs root.
        local primary src_dir
        primary=$(primary_of "$dev") || {
            echo "Error: $dev bind-> $mnt has no primary assignment."
            return 1
        }
        src_dir="$INSTALL_POINT$primary/${mnt#/}"
        mkdir -p "$src_dir"
        print_step "Bind mounting $src_dir to $target..."
        mount --bind "$src_dir" "$target"
        if mountpoint -q "$target"; then
            echo "$src_dir bound successfully on $target."
        else
            echo "Error: failed to bind $src_dir on $target"
            return 1
        fi
        return 0
    fi
    dev=$(real_dev "$dev")
    local opts
    opts=$(mount_opts_for "$fs")
    print_step "Mounting $dev to $target${opts:+ ($opts)}..."
    if [[ -n "$opts" ]]; then
        mount -o "$opts" "$dev" "$target"
    else
        mount "$dev" "$target"
    fi
    if mountpoint -q "$target"; then
        echo "$dev mounted successfully on $target."
    else
        echo "Error: failed to mount $dev on $target"
        return 1
    fi
}

# fstab generator. genfstab cannot reliably express subdir bind mounts, so we
# write fstab ourselves from the planner plan: UUID lines for regular
# partitions and swaps, path-based "none bind" lines for bind mounts.
generate_fstab() {
    print_step "Generating fstab..."
    local spec dev mnt fs fmt enc uuid opts pass primary src cname
    local -a crypttab=()
    mkdir -p "$INSTALL_POINT/etc"
    # Keyfiles were stashed in a temp dir during format_all (root partition was
    # not mounted at INSTALL_POINT yet back then); move them into the target now
    if [[ -n "${KEYFILE_DIR:-}" && -n "$(ls -A "$KEYFILE_DIR" 2>/dev/null)" ]]; then
        mkdir -p "$INSTALL_POINT/etc/cryptsetup-keys.d"
        cp -a "$KEYFILE_DIR"/. "$INSTALL_POINT/etc/cryptsetup-keys.d/"
        chmod 600 "$INSTALL_POINT/etc/cryptsetup-keys.d/"*.key
    fi
    : > "$INSTALL_POINT/etc/fstab"

    local -a ordered
    # Safe order: root, regular mounts by depth, binds by depth, swaps
    mapfile -t ordered < <(printf '%s\n' "${MOUNTS[@]}" | awk -F'|' '
        $2 == "/"       { print "0 0", $0; next }
        $2 == "swap"    { print "3 0", $0; next }
        $3 == "inherit" { print "2", split($2, a, "/") - 1, $0; next }
        { print "1", split($2, a, "/") - 1, $0 }' \
        | sort -k1,1 -k2,2n | cut -d' ' -f3-)

    for spec in "${ordered[@]}"; do
        IFS='|' read -r dev mnt fs fmt enc <<<"$spec"
        if [[ "$fs" == "inherit" ]]; then
            primary=$(primary_of "$dev") || {
                echo "Error: no primary assignment for bind $mnt of $dev"
                return 1
            }
            # Bind source is a system path at boot: <primary>/<subdir>
            echo "$primary/${mnt#/}  $mnt  none  bind  0  0" >> "$INSTALL_POINT/etc/fstab"
            continue
        fi
        local src
        if [[ "$fs" == "swap" ]]; then
            uuid=$(blkid -s UUID -o value "$dev")
            echo "UUID=$uuid  none  swap  sw  0  0" >> "$INSTALL_POINT/etc/fstab"
            continue
        fi
        if [[ "$mnt" == "/" && "$enc" == "yes" ]]; then
            # fs UUID lives on the OPENED mapper, not on the raw LUKS container
            uuid=$(blkid -s UUID -o value "/dev/mapper/$CRYPTROOT_NAME")
            src="UUID=$uuid"
        elif [[ "$enc" == "yes" ]]; then
            cname=$(crypt_name "$mnt")
            src="/dev/mapper/$cname"
            crypttab+=("$cname  UUID=$(blkid -s UUID -o value "$(real_dev "$dev")")  /etc/cryptsetup-keys.d/$cname.key  luks,discard")
        else
            uuid=$(blkid -s UUID -o value "$(real_dev "$dev")")
            if [[ -z "$uuid" ]]; then
                echo "Error: could not read UUID of $dev, fstab incomplete."
                return 1
            fi
            src="UUID=$uuid"
        fi
        opts=$(mount_opts_for "$fs")
        [[ -n "$opts" ]] && opts="$opts,"
        pass=0
        if [[ "$mnt" == "/" ]]; then
            pass=1
        else
            case "$fs" in ext4|f2fs) pass=2 ;; esac
        fi
        echo "$src  $mnt  $fs  ${opts}defaults  0  $pass" >> "$INSTALL_POINT/etc/fstab"
    done
    if [[ ${#crypttab[@]} -gt 0 ]]; then
        {
            echo "# <name>  <LUKS UUID>  <keyfile>  <options>"
            printf '%s\n' "${crypttab[@]}"
        } > "$INSTALL_POINT/etc/crypttab"
        echo "crypttab written:"
        cat "$INSTALL_POINT/etc/crypttab"
    fi
    if [[ ${#RAIDSETS[@]} -gt 0 ]]; then
        # udev rules of the mdadm package auto-assemble arrays listed here
        print_step "Writing mdadm.conf..."
        mdadm --detail --scan >> "$INSTALL_POINT/etc/mdadm.conf"
        cat "$INSTALL_POINT/etc/mdadm.conf"
    fi
    echo "fstab written:"
    cat "$INSTALL_POINT/etc/fstab"
}

mount_all() {
    local spec dev mnt fs fmt
    mkdir -p "$INSTALL_POINT"

    # Root first, everything else after it in mountpoint-depth order
    for spec in "${MOUNTS[@]}"; do
        IFS='|' read -r dev mnt fs fmt enc <<<"$spec"
        [[ "$mnt" == "/" ]] || continue
        mount_one "$root_device" "/" "$fs" || return 1
    done

    local -a _parts _binds
    mapfile -t _parts < <(printf '%s\n' "${MOUNTS[@]}" \
        | awk -F'|' '$2 != "/" && $2 != "swap" && $3 != "inherit" { print split($2, a, "/") - 1, $0 }' \
        | sort -n | cut -d' ' -f2-)
    # Bind mounts come last: their primary mountpoint must be mounted first
    mapfile -t _binds < <(printf '%s\n' "${MOUNTS[@]}" \
        | awk -F'|' '$3 == "inherit" { print split($2, a, "/") - 1, $0 }' \
        | sort -n | cut -d' ' -f2-)

    local _spec
    for _spec in "${_parts[@]}"; do
        IFS='|' read -r dev mnt fs fmt enc <<<"$_spec"
        mount_one "$dev" "$mnt" "$fs" || return 1
    done
    for _spec in "${_binds[@]}"; do
        IFS='|' read -r dev mnt fs fmt enc <<<"$_spec"
        mount_one "$dev" "$mnt" "$fs" || return 1
    done

    # Activate swap partitions
    for spec in "${MOUNTS[@]}"; do
        IFS='|' read -r dev mnt fs fmt enc <<<"$spec"
        [[ "$mnt" == "swap" ]] || continue
        if swapon "$dev" 2>/dev/null; then
            echo "Swap on $dev activated."
        else
            echo "Warning: could not activate swap on $dev (missing swap signature? choose format=yes)."
        fi
    done
}

install_base_system() {
    # Determine which mesa package to use
    local mesa_pkg="mesa"
    if [[ "$pacman_config" == *"V3"* ]] || [[ "$pacman_config" == *"V4"* ]]; then
        mesa_pkg="mesa-git"
    fi

    # Base packages including the chosen kernel and base-devel
    base_packages="base base-devel dhcpcd $kernel_package power-profiles-daemon pacman nano git sudo linux-firmware wireless-regdb efibootmgr networkmanager bluez bluez-utils htop fastfetch wireplumber git mkinitcpio reflector zsh zsh-theme-powerlevel10k cachyos-rate-mirrors $mesa_pkg"

    # Filesystem tools needed by ANY assigned partition (root or otherwise)
    local spec fs enc
    if [[ -n "${MOUNTS[*]:-}" ]]; then
        for spec in "${MOUNTS[@]}"; do
            fs=$(cut -d'|' -f3 <<<"$spec")
            enc=$(cut -d'|' -f5 <<<"$spec")
            case $fs in
                btrfs) base_packages="$base_packages btrfs-progs" ;;
                f2fs)  base_packages="$base_packages f2fs-tools" ;;
            esac
            if [[ "$enc" == "yes" || "$encryption" == "yes" ]]; then
                base_packages="$base_packages cryptsetup"
            fi
        done
        if [[ ${#RAIDSETS[@]} -gt 0 ]]; then
            base_packages="$base_packages mdadm"
        fi
    else
        case $filesystem in
            "btrfs") base_packages="$base_packages btrfs-progs" ;;
            "f2fs")  base_packages="$base_packages f2fs-tools" ;;
        esac
    fi

    # Desktop environment packages
    case $desktop_environment in
        "gnome")
            base_packages="$base_packages sddm gnome $adpackages"
            ;;
        "kde")
            # plasma-meta = full desktop (spectacle, widgets, wayland session) minus
            # group cruft: plasma-bigscreen/nano/sdk. X11 stack dropped.
            base_packages="$base_packages sddm wayland plasma-meta konsole dolphin ark $adpackages"
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
        generate_fstab
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

# Enable installer LOCALE plus cs_CZ (Plasma skeleton plasma-localerc forces
# LANG=cs_CZ.UTF-8, so it must exist or every setlocale() warns/fails)
sed -i -E "s/^#($LOCALE|cs_CZ\.UTF-8)( +UTF-8)/\1\2/" /etc/locale.gen
grep -q "^$LOCALE" /etc/locale.gen || echo "$LOCALE UTF-8" >> /etc/locale.gen
grep -q '^cs_CZ.UTF-8' /etc/locale.gen || echo 'cs_CZ.UTF-8 UTF-8' >> /etc/locale.gen

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
# Root on mdadm array: assemble the array in the initramfs before root mount
# (mdadm.conf is written before chroot, the mdadm_udev hook embeds it)
if [[ "$root_partition" == /dev/md/* ]]; then
    sed -i 's/modconf block /modconf block mdadm_udev /' /etc/mkinitcpio.conf
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
    local root_uuid=""
    local ROOT_PARAM=""
    if [ "$encryption" = "yes" ]; then
        luks_uuid=$(blkid -s UUID -o value "$root_partition")
        if [ -z "$luks_uuid" ]; then
            echo "Error: could not determine UUID of LUKS container $root_partition"
            return 1
        fi
    else
        if [[ "$root_partition" == /dev/md/* ]]; then
            # md arrays have no PARTUUID - use the filesystem UUID
            root_uuid=$(blkid -s UUID -o value "$root_device")
            if [ -z "$root_uuid" ]; then
                echo "Error: could not determine UUID of $root_device"
                return 1
            fi
            ROOT_PARAM="root=UUID=$root_uuid"
        else
            root_partuuid=$(blkid -s PARTUUID -o value "$root_device")
            if [ -z "$root_partuuid" ]; then
                echo "Error: could not determine PARTUUID of $root_device"
                return 1
            fi
            ROOT_PARAM="root=PARTUUID=$root_partuuid"
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
    cat << EOL > /boot/loader/entries/arch.conf
title   MYKYcorp ($kernel_package)
linux   /vmlinuz-$kernel_package
initrd  /initramfs-$kernel_package.img
options $ROOT_PARAM rw $KERNEL_PARAMS
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
    local root_uuid=""
    local ROOT_PARAM=""
    if [ "$encryption" = "yes" ]; then
        luks_uuid=$(blkid -s UUID -o value "$root_partition")
        if [ -z "$luks_uuid" ]; then
            echo "Error: could not determine UUID of LUKS container $root_partition"
            return 1
        fi
    else
        if [[ "$root_partition" == /dev/md/* ]]; then
            # md arrays have no PARTUUID - use the filesystem UUID
            root_uuid=$(blkid -s UUID -o value "$root_device")
            if [ -z "$root_uuid" ]; then
                echo "Error: could not determine UUID of $root_device"
                return 1
            fi
            ROOT_PARAM="root=UUID=$root_uuid"
        else
            root_partuuid=$(blkid -s PARTUUID -o value "$root_device")
            if [ -z "$root_partuuid" ]; then
                echo "Error: could not determine PARTUUID of $root_device"
                return 1
            fi
            ROOT_PARAM="root=PARTUUID=$root_partuuid"
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
        # For unencrypted systems: PARTUUID, or UUID for md arrays (no PARTUUID)
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${ROOT_PARAM} ${KERNEL_PARAMS}\"|" /etc/default/grub
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
    local root_uuid=""
    local ROOT_PARAM=""
    if [ "$encryption" = "yes" ]; then
        luks_uuid=$(blkid -s UUID -o value "$root_partition")
        if [ -z "$luks_uuid" ]; then
            echo "Error: could not determine UUID of LUKS container $root_partition"
            return 1
        fi
    else
        if [[ "$root_partition" == /dev/md/* ]]; then
            # md arrays have no PARTUUID - use the filesystem UUID
            root_uuid=$(blkid -s UUID -o value "$root_device")
            if [ -z "$root_uuid" ]; then
                echo "Error: could not determine UUID of $root_device"
                return 1
            fi
            ROOT_PARAM="root=UUID=$root_uuid"
        else
            root_partuuid=$(blkid -s PARTUUID -o value "$root_device")
            if [ -z "$root_partuuid" ]; then
                echo "Error: could not determine PARTUUID of $root_device"
                return 1
            fi
            ROOT_PARAM="root=PARTUUID=$root_partuuid"
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
        # For unencrypted systems: PARTUUID, or UUID for md arrays (no PARTUUID)
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${ROOT_PARAM} ${KERNEL_PARAMS}\"|" /etc/default/grub
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
    local root_uuid=""
    local ROOT_PARAM=""
    local disk=""
    if [ "$encryption" = "yes" ]; then
        luks_uuid=$(blkid -s UUID -o value "$root_partition")
        if [ -z "$luks_uuid" ]; then
            echo "Error: could not determine UUID of LUKS container $root_partition"
            return 1
        fi
    else
        if [[ "$root_partition" == /dev/md/* ]]; then
            # md arrays have no PARTUUID - use the filesystem UUID
            root_uuid=$(blkid -s UUID -o value "$root_device")
            if [ -z "$root_uuid" ]; then
                echo "Error: could not determine UUID of $root_device"
                return 1
            fi
            ROOT_PARAM="root=UUID=$root_uuid"
        else
            root_partuuid=$(blkid -s PARTUUID -o value "$root_device")
            if [ -z "$root_partuuid" ]; then
                echo "Error: could not determine PARTUUID of $root_device"
                return 1
            fi
            ROOT_PARAM="root=PARTUUID=$root_partuuid"
        fi
    fi
    if [[ "$root_partition" == /dev/md/* ]]; then
        # BIOS boot on md: install to every member disk of the array
        local mdname="${root_partition#/dev/md/}" set
        disk=""
        for set in "${RAIDSETS[@]}"; do
            if [[ "$(cut -d'|' -f1 <<<"$set")" == "$mdname" ]]; then
                disk=$(cut -d'|' -f3 <<<"$set")
            fi
        done
        if [ -z "$disk" ]; then
            echo "Error: could not find members of $root_partition in RAIDSETS"
            return 1
        fi
    else
        # Resolve the parent disk properly (works for /dev/sda2 and /dev/nvme0n1p1)
        disk=$(lsblk -nro PKNAME "$root_partition" | head -n1)
        disk="/dev/$disk"
    fi
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
        # For unencrypted systems: PARTUUID, or UUID for md arrays (no PARTUUID)
        sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${ROOT_PARAM} ${KERNEL_PARAMS}\"|" /etc/default/grub
    fi
    # Theme and timing tweaks
    sed -i 's|^#GRUB_TIMEOUT=[0-9]\+|GRUB_TIMEOUT=3|' /etc/default/grub
    sed -i 's|^#GRUB_DISABLE_OS_PROBER=false|GRUB_DISABLE_OS_PROBER=false|' /etc/default/grub
    sed -i 's|^GRUB_TIMEOUT_STYLE=hidden|#GRUB_TIMEOUT_STYLE=hidden|' /etc/default/grub
    # Install GRUB to MBR (loop handles multi-disk md arrays)
    for d in ${disk}; do
        grub-install \
          --target=i386-pc \
          --recheck \
          --boot-directory=/boot \
          ${d}
    done
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
