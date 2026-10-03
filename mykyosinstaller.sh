#!/bin/bash
TCP_CONGESTION_CONTROL=bic
TIMEZONE="Europe/Prague"
LOCALE="en_US.UTF-8"
KEYMAP="cz-qwertz"
SWAPPINESS="100"
KERNEL_PARAMS="zswap.max_pool_percent=50 zswap.shrinker_enabled=0 processor.ignore_ppc=1 no_timer_check nowatchdog mem_sleep_default=deep transparent_hugepage=madvise split_lock_detect=off tsc=reliable clocksource=tsc audit=0 mce=off preempt=lazy rcutree.rcu_normal_wake_from_gp=1 mitigations=off random.trust_cpu=on iommu=pt"
INSTALL_POINT="/archinstaller"
BTRFS_MOUNT_OPTIONS="autodefrag,noatime,compress=zstd:3,space_cache=v2,ssd,discard=async"
BTRFS_MOUNT_OPTIONS_HDD="autodefrag,noatime,compress=zstd:3,space_cache=v2"

F2FS_MOUNT_OPTIONS="defaults,noatime,lazytime,discard,flush_merge,inline_xattr,inline_data,inline_dentry,mode=adaptive,compress_algorithm=zstd:6,compress_cache"
F2FS_FORMAT_FEATURES="extra_attr,inode_checksum,sb_checksum,compression"
EXT4_MOUNT_OPTIONS="noatime,commit=60,barrier=0"

# ============================================================================
# TUI plumbing (whiptail / libnewt, present on the archiso)
# ============================================================================
if ! command -v whiptail >/dev/null 2>&1; then
    echo "whiptail not found, attempting to install libnewt..."
    pacman -Sy --noconfirm libnewt >/dev/null 2>&1
fi
command -v whiptail >/dev/null 2>&1 || { echo "FATAL: whiptail (libnewt) unavailable."; exit 1; }

die() { echo "FATAL: $*" >&2; exit 1; }

# All ui_* helpers store their result in a fixed variable and return nonzero
# on Cancel/ESC so callers can treat that as "user wants out".
# NOTE: no 0 0 0 autosize - some whiptail builds segfault on it.
ui_menu() { # ui_menu TITLE PROMPT tag desc [tag desc...]
    local title="$1" prompt="$2"
    shift 2
    local count=$(( $# / 2 ))
    local h=$(( count + 8 )); (( h > 26 )) && h=26
    local lh=$(( count )); (( lh > 14 )) && lh=14
    MENU_RESULT=$(whiptail --title "$title" --menu "$prompt" "$h" 78 "$lh" "${@}" 3>&1 1>&2 2>&3)
}
ui_input() { # ui_input TITLE PROMPT [DEFAULT]
    INPUT_RESULT=$(whiptail --title "$1" --inputbox "$2" 9 70 "${3:-}" 3>&1 1>&2 2>&3)
}
ui_password() { # ui_password TITLE PROMPT
    PASSWORD_RESULT=$(whiptail --title "$1" --passwordbox "$2" 9 70 3>&1 1>&2 2>&3)
}
ui_yesno() { # returns 0 on Yes
    whiptail --title "$1" --yesno "$2" 9 70
}
ui_yesno_safe() { # like ui_yesno but default answer is No (for destructive stuff)
    whiptail --title "$1" --yesno --defaultno "$2" 9 70
}
ui_msg() {
    whiptail --title "$1" --msgbox --scrolltext "$2" 22 80
}

# ============================================================================
# Disk planner: build the MOUNTS array ("device|mountpoint|fstype|format|enc")
# Supports arbitrary multi-disk layouts: /, /boot, /home, /var, /tmp, swap,
# custom mountpoints - one or more per disk.
# ============================================================================
MOUNTS=()
# RAID sets: "name|level|dev1 dev2 ..." - MOUNTS reference them as device md:<name>
RAIDSETS=()

member_in_use() {
    local d="$1" set name level members m
    for set in "${RAIDSETS[@]}"; do
        IFS='|' read -r name level members <<<"$set"
        for m in $members; do [[ "$m" == "$d" ]] && return 0; done
    done
    for set in "${MOUNTS[@]}"; do
        [[ "${set%%|*}" == "$d" ]] && return 0
    done
    return 1
}

add_raid_set() {
    if ! ui_menu "RAID" "RAID level:" \
        "0" "RAID0 stripe - performance, NO redundancy (one disk dies -> all data gone)" \
        "1" "RAID1 mirror - survives one disk failure, half the capacity (2+ disks)" \
        "10" "RAID10 stripe+mirror (4+ disks)" \
        "5" "RAID5 parity - survives one failure, capacity N-1 (3+ disks)"
    then
        return
    fi
    local level="$MENU_RESULT"
    local min=2
    [[ $level == 5 ]] && min=3
    [[ $level == 10 ]] && min=4

    local -a members=()
    while true; do
        local -a ditems=()
        local name size fstype dev other
        while read -r name size fstype; do
            dev="/dev/$name"
            for other in "${members[@]}"; do
                [[ "$other" == "$dev" ]] && continue 2
            done
            member_in_use "$dev" && continue
            ditems+=("$dev" "${size:-?} ${fstype:-empty}")
        done < <(device_list)
        ditems+=("done" "Finish member selection (${#members[@]} selected, need $min)")

        if ! ui_menu "RAID" "Pick member disks for the array:" "${ditems[@]}"; then
            if [[ ${#members[@]} -ge $min ]]; then
                break
            fi
            return
        fi
        [[ "$MENU_RESULT" == "done" ]] && break
        members+=("$MENU_RESULT")
    done
    if [[ ${#members[@]} -lt $min ]]; then
        ui_msg "RAID" "RAID$level needs at least $min disks."
        return
    fi

    local name="md${#RAIDSETS[@]}"
    RAIDSETS+=("$name|$level|${members[*]}")
    ui_msg "RAID" "Created array /dev/md/$name (RAID$level, members: ${members[*]})\n\nNow use Add and pick device md:$name to put a filesystem on it."
}

raid_menu() {
    while true; do
        local -a items=()
        local i set name level members used s
        for i in "${!RAIDSETS[@]}"; do
            IFS='|' read -r name level members <<<"${RAIDSETS[$i]}"
            items+=("$i" "/dev/md/$name  RAID$level  members: $members")
        done
        items+=("add" "Create new RAID array")
        items+=("back" "Back to planner")

        if ! ui_menu "RAID arrays" "Current arrays:" "${items[@]}"; then
            return
        fi
        case "$MENU_RESULT" in
            add)   add_raid_set ;;
            back)  return ;;
            *)
                if [[ "$MENU_RESULT" =~ ^[0-9]+$ ]]; then
                    name=$(cut -d'|' -f1 <<<"${RAIDSETS[$MENU_RESULT]}")
                    used=""
                    for s in "${MOUNTS[@]}"; do
                        [[ "${s%%|*}" == "md:$name" ]] && used="yes"
                    done
                    if [[ -n "$used" ]]; then
                        ui_msg "RAID arrays" "Array md:$name is used by mountpoint assignments - remove those first."
                    elif ui_yesno_safe "RAID arrays" "Remove RAID array md:$name?"; then
                        unset "RAIDSETS[$MENU_RESULT]"
                        RAIDSETS=("${RAIDSETS[@]}")
                    fi
                fi
                ;;
        esac
    done
}

# First regular (non-bind, non-swap) mountpoint of a device - its "primary".
# Bind entries (fs=inherit) hang off the primary.
primary_of_device() {
    local want="$1" spec d m f
    for spec in "${MOUNTS[@]}"; do
        IFS='|' read -r d m f _ _ <<<"$spec"
        if [[ "$d" == "$want" && "$f" != "inherit" && "$m" != "swap" ]]; then
            echo "$m"
            return
        fi
    done
    echo "(dangling - no primary!)"
}

planner_summary() {
    if [[ ${#RAIDSETS[@]} -gt 0 ]]; then
        local set name level members
        echo "RAID arrays:"
        for set in "${RAIDSETS[@]}"; do
            IFS='|' read -r name level members <<<"$set"
            echo "  /dev/md/$name  RAID$level  [$members]"
        done
    fi
    if [[ ${#MOUNTS[@]} -eq 0 ]]; then
        echo "(no mountpoint assignments yet)"
        return
    fi
    local spec dev mnt fs fmt out=""
    for spec in "${MOUNTS[@]}"; do
        IFS='|' read -r dev mnt fs fmt enc <<<"$spec"
        local tags="$fs, $( [[ $fmt == yes ]] && echo FORMAT || echo keep )"
        [[ $enc == "yes" ]] && tags+=", LUKS"
        if [[ $fs == "inherit" ]]; then
            out+="$dev bind-> $mnt  [folder ${mnt#/} on $(primary_of_device "$dev")]\n"
        else
            out+="$dev -> $mnt  [$tags]\n"
        fi
    done
    echo -e "$out"
}

device_list() {
    # prints "name size fstype" for all partitions on the system
    lsblk -nrno NAME,SIZE,TYPE,FSTYPE 2>/dev/null | awk '$3 == "part" { print $1, $2, $4 }'
}

add_assignment() {
    local -a ditems=()
    local name size fstype dev
    while read -r name size fstype; do
        dev="/dev/$name"
        local other assigned=""
        for other in "${MOUNTS[@]}"; do
            if [[ "${other%%|*}" == "$dev" ]]; then
                assigned="yes"
                break
            fi
        done
        if [[ -n "$assigned" ]]; then
            ditems+=("$dev" "${size:-?} ${fstype:-empty} (assigned: extra mountpoints = bind)")
        else
            ditems+=("$dev" "${size:-?} ${fstype:-empty}")
        fi
    done < <(device_list)
    local set name level members
    for set in "${RAIDSETS[@]}"; do
        IFS='|' read -r name level members <<<"$set"
        ditems+=("md:$name" "RAID$level array [$members]")
    done
    ditems+=("other" "Type a device path manually")

    if ! ui_menu "Disk planner" "Pick a partition to assign:" "${ditems[@]}"; then
        return
    fi
    local dev="$MENU_RESULT"
    if [[ "$dev" == "other" ]]; then
        ui_input "Disk planner" "Enter device path (e.g. /dev/sda3):" || return
        dev="$INPUT_RESULT"
        [[ "$dev" == /dev/* ]] || { ui_msg "Disk planner" "Device must start with /dev/"; return; }
        [[ -b "$dev" ]] || { ui_msg "Disk planner" "$dev is not a block device."; return; }
    fi

    # Mountpoint (RAID arrays: no /boot, no / - initramfs md support not implemented)
    local -a mitems=("/home" "User home directories" \
                     "/var" "Variable data (logs, pacman cache...)" \
                     "/tmp" "Temp files" \
                     "other" "Enter a custom mountpoint")
    if [[ "$dev" != md:* ]]; then
        mitems=("/" "Root filesystem (required, exactly one)" \
                "/boot" "EFI System Partition / boot" \
                "swap" "Swap partition" \
                "${mitems[@]}")
    else
        mitems=("/" "Root filesystem on RAID (assembled by mdadm in initramfs)" \
                "${mitems[@]}")
    fi
    if ! ui_menu "Disk planner" "Where should $dev be mounted?" "${mitems[@]}"; then
        return
    fi
    local mnt="$MENU_RESULT"
    if [[ "$mnt" == "other" ]]; then
        ui_input "Disk planner" "Enter mountpoint (must start with /):" || return
        mnt="$INPUT_RESULT"
        [[ "$mnt" =~ ^/[A-Za-z0-9_./-]*$ && "$mnt" != "/" ]] \
            || { ui_msg "Disk planner" "Invalid mountpoint '$mnt'."; return; }
    fi

    # Duplicate mountpoint check (multiple swaps are fine)
    if [[ "$mnt" != "swap" ]]; then
        local s other
        for other in "${MOUNTS[@]}"; do
            IFS='|' read -r _ _ omnt _ _ <<<"$other"
            [[ "$omnt" == "$mnt" ]] && { ui_msg "Disk planner" "$mnt is already assigned."; return; }
        done
    fi
    # Already assigned? Then this is a bind mount of its primary mountpoint
    local is_bind="no" other_fs="" other_mnt=""
    for other in "${MOUNTS[@]}"; do
        if [[ "${other%%|*}" == "$dev" ]]; then
            IFS='|' read -r _ _ other_fs other_mnt _ <<<"$other"
            other_mnt=$(cut -d'|' -f2 <<<"$other")
            break
        fi
    done
    if [[ "$other_fs" == "swap" ]]; then
        ui_msg "Disk planner" "$dev is set up as swap - swap partitions cannot hold filesystems."
        return
    fi
    if [[ -n "$other_fs" ]]; then
        if [[ "$other_mnt" == "/" ]]; then
            ui_msg "Disk planner" "Binds from the root partition make no sense -\nit is already visible everywhere on the system."
            return
        fi
        ui_msg "Disk planner" "$dev already has a primary mountpoint ($other_mnt).\n\nThis assignment becomes a BIND mount of a folder on it:\nthe shared filesystem keeps one folder per mountpoint (${mnt#/}),\neach bind target sees only its own folder.\nFilesystem and format are decided on the first assignment."
        is_bind="yes"
    fi
    if [[ "$is_bind" == "yes" ]]; then
        if [[ "$mnt" == "/" ]]; then
            ui_msg "Disk planner" "Root (/) cannot be a bind mount."
            return
        fi
        if [[ "$mnt" == "swap" ]]; then
            ui_msg "Disk planner" "Swap cannot be a bind mount."
            return
        fi
    fi

    # Filesystem (swap is fixed, bind entries inherit from the primary)
    local fs=""
    if [[ "$is_bind" == "yes" ]]; then
        fs="inherit"
    elif [[ "$mnt" != "swap" ]]; then
        if ! ui_menu "Disk planner" "Filesystem for $dev ($mnt):" \
            "ext4" "the universal, recommended" \
            "btrfs" "terminator, cant kill" \
            "f2fs" "flash memory optimized, recommended" \
            "vfat" "FAT32 (for EFI system partitions)"
        then
            return
        fi
        fs="$MENU_RESULT"
        if [[ "$mnt" == "/" && "$fs" == "vfat" ]]; then
            ui_msg "Disk planner" "Root cannot be vfat."
            return
        fi
    fi

    # Encryption? (per partition; swap and binds excluded, ESP impossible)
    local enc="no"
    if [[ "$is_bind" != "yes" && "$mnt" != "swap" && "$mnt" != "/boot" ]]; then
        if ui_yesno_safe "Disk planner" "Encrypt $dev with LUKS?\n\nYou will type a passphrase for it during formatting;\nat boot it unlocks automatically via a keyfile on the encrypted root\n(if the root is NOT encrypted, you will type this passphrase at every boot)."; then
            enc="yes"
        fi
    fi

    # Format?
    local fmt="no"
    if [[ "$is_bind" == "yes" ]]; then
        fmt="inherit"
    elif [[ "$enc" == "yes" ]]; then
        fmt="yes"   # LUKS container must be created fresh, implies format
    elif ui_yesno_safe "Disk planner" "Format $dev as ${fs:-swap}?\n\nWARNING: ALL DATA on $dev will be DESTROYED."; then
        fmt="yes"
    fi

    MOUNTS+=("$dev|$mnt|${fs:-swap}|$fmt|$enc")
    if [[ "$is_bind" == "yes" ]]; then
        ui_msg "Disk planner" "Added: $dev bind-> $mnt (folder ${mnt#/} on $other_mnt)"
    else
        local tags="${fs:-swap}, $([ "$fmt" = yes ] && echo format || echo keep)"
        [[ $enc == "yes" ]] && tags+=", LUKS"
        ui_msg "Disk planner" "Added: $dev -> $mnt ($tags)"
    fi
}

validate_plan() {
    local spec dev mnt fs roots=0 p
    for spec in "${MOUNTS[@]}"; do
        mnt=$(cut -d'|' -f2 <<<"$spec")
        [[ "$mnt" == "/" ]] && roots=$((roots+1))
    done
    if [[ "$roots" -ne 1 ]]; then
        ui_msg "Disk planner" "You must assign exactly ONE root (/) partition.\nCurrently assigned: $roots"
        return 1
    fi
    # Bind entries need their primary to still exist
    for spec in "${MOUNTS[@]}"; do
        IFS='|' read -r dev mnt fs _ _ <<<"$spec"
        if [[ $fs == "inherit" ]]; then
            p=$(primary_of_device "$dev")
            if [[ "$p" == "(dangling"* ]]; then
                ui_msg "Disk planner" "Bind assignment $dev -> $mnt has no primary mountpoint left.\nRemove it, or re-add $dev with its first (primary) mountpoint."
                return 1
            fi
        fi
    done
    # RAID consistency
    local set name level members used s
    for spec in "${MOUNTS[@]}"; do
        dev=$(cut -d'|' -f1 <<<"$spec")
        mnt=$(cut -d'|' -f2 <<<"$spec")
        if [[ "$dev" == md:* ]]; then
            if [[ "$mnt" == "swap" ]]; then
                ui_msg "Disk planner" "Swap cannot live on a RAID array (excluded by design)."
                return 1
            fi
            used=""
            for set in "${RAIDSETS[@]}"; do
                [[ "md:$(cut -d'|' -f1 <<<"$set")" == "$dev" ]] && used="yes"
            done
            if [[ -z "$used" ]]; then
                ui_msg "Disk planner" "Assignment uses $dev but no such RAID array exists."
                return 1
            fi
        fi
    done
    for set in "${RAIDSETS[@]}"; do
        name=$(cut -d'|' -f1 <<<"$set")
        used=""
        for s in "${MOUNTS[@]}"; do
            [[ "${s%%|*}" == "md:$name" ]] && used="yes"
        done
        [[ -z "$used" ]] && ui_msg "Disk planner" "Warning: RAID array md:$name exists but no mountpoint uses it."
    done
    return 0
}

partition_editor() {
    while true; do
        local -a items=()
        local i spec
        for i in "${!MOUNTS[@]}"; do
            IFS='|' read -r dev mnt fs fmt enc <<<"${MOUNTS[$i]}"
            if [[ $fs == "inherit" ]]; then
                items+=("$i" "$dev bind-> $mnt (folder ${mnt#/} on $(primary_of_device "$dev"))")
            else
                local itags="$fs, $( [[ $fmt == yes ]] && echo FORMAT || echo keep )"
                [[ $enc == "yes" ]] && itags+=", LUKS"
                items+=("$i" "$dev -> $mnt ($itags)")
            fi
        done
        items+=("add" "Add mountpoint assignment")
        items+=("raid" "Manage RAID arrays")
        items+=("lsblk" "Show disks and partitions")
        items+=("done" "Done - continue with these")

        if ! ui_menu "Disk planner" "Current plan:\n$(planner_summary)" "${items[@]}"; then
            ui_yesno "Disk planner" "Cancel installation?" && die "Installation cancelled."
            continue
        fi

        case "$MENU_RESULT" in
            add)
                add_assignment
                ;;
            raid)
                raid_menu
                ;;
            lsblk)
                ui_msg "Disks" "$(lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL)"
                ;;
            done)
                if validate_plan; then
                    break
                fi
                ;;
            *)
                # numeric: remove that assignment
                if [[ "$MENU_RESULT" =~ ^[0-9]+$ ]]; then
                    if ui_yesno_safe "Disk planner" "Remove assignment ${MOUNTS[$MENU_RESULT]}?"; then
                        unset "MOUNTS[$MENU_RESULT]"
                        MOUNTS=("${MOUNTS[@]}")
                    fi
                fi
                ;;
        esac
    done

    # Extract root assignment into the variables the installer functions expect
    local spec
    for spec in "${MOUNTS[@]}"; do
        if [[ $(cut -d'|' -f2 <<<"$spec") == "/" ]]; then
            root_partition=$(cut -d'|' -f1 <<<"$spec")
            filesystem=$(cut -d'|' -f3 <<<"$spec")
            encryption=$(cut -d'|' -f5 <<<"$spec")
            break
        fi
    done
}

ask_password() { # ask_password TITLE VARNAME
    local pass1 pass2
    while true; do
        ui_password "$1" "Enter password:" || die "Installation cancelled."
        pass1="$PASSWORD_RESULT"
        ui_password "$1" "Confirm password:" || die "Installation cancelled."
        pass2="$PASSWORD_RESULT"
        if [[ -z "$pass1" ]]; then
            ui_msg "$1" "Password cannot be empty."
        elif [[ "$pass1" != "$pass2" ]]; then
            ui_msg "$1" "Passwords do not match, try again."
        else
            printf -v "$2" '%s' "$pass1"
            return
        fi
    done
}

# ============================================================================
# Information gathering
# ============================================================================
echo "MYKYOS installer"

ui_menu "Mode" "Choose installation mode:" \
    "partitions" "Install to physical partitions (TUI disk planner)" \
    "archive" "Build a rootfs archive only" \
    || die "Installation cancelled."

if [[ "$MENU_RESULT" == "archive" ]]; then
    INSTALL_MODE="archive"
    ui_input "Archive" "Output path for the rootfs archive:" "/rootfs.tar.gz" \
        || die "Installation cancelled."
    archive_output_path="${INPUT_RESULT:-/rootfs.tar.gz}"
    INSTALL_POINT=$(mktemp -d /tmp/mykyos_rootfs.XXXXXX)
    bootloader="none"
    encryption="no"
    filesystem="none"
else
    INSTALL_MODE="partitions"
    partition_editor

    if [[ "$filesystem" == "btrfs" ]]; then
        ui_menu "Btrfs tuning" "Is the root disk an HDD or SSD?" \
            "ssd" "SSD / NVMe (ssd mode, async discard)" \
            "hdd" "HDD (no ssd mode, no discard, autodefrag)" \
            || die "Installation cancelled."
        [[ "$MENU_RESULT" == "hdd" ]] && BTRFS_MOUNT_OPTIONS="$BTRFS_MOUNT_OPTIONS_HDD"
    fi

    case "$filesystem" in
        "f2fs") KERNEL_PARAMS="$KERNEL_PARAMS rootflags=atgc,gc_merge,noatime,compress_algorithm=zstd:6,compress_cache" ;;
        "ext4") KERNEL_PARAMS="$KERNEL_PARAMS rootflags=noatime,lazytime,discard,commit=60,dioread_nolock" ;;
    esac

    # Encryption is now chosen per partition in the disk planner;
    # $encryption reflects the ROOT assignment (drives initramfs hooks).
    [[ "$encryption" == "yes" ]] && KERNEL_PARAMS="$KERNEL_PARAMS rd.luks.options=discard"
fi

# Desktop environment
ui_menu "Desktop" "Desired desktop environment (gnome>kde>mate>xfce>lxqt>none>mini>pico):" \
    "gnome" "GNOME + sddm" \
    "kde" "Plasma-meta + sddm (full desktop, no group cruft)" \
    "xfce" "XFCE + sddm" \
    "mate" "MATE + sddm" \
    "lxqt" "LXQt + xorg" \
    "none" "Base system only (full base packages)" \
    "mini" "Minimal: rate-mirrors, base, NM, sudo, kernel" \
    "pico" "Bare: rate-mirrors, mkinitcpio, kernel" \
    || die "Installation cancelled."
desktop_environment="$MENU_RESULT"

ui_input "Packages" "Additional packages (space separated, empty is fine):" \
    || die "Installation cancelled."
adpackages="$INPUT_RESULT"

ui_input "Hostname" "Desired hostname:" "mykyos" || die "Installation cancelled."
HOSTNAME="${INPUT_RESULT:-mykyos}"
CRYPTROOT_NAME="$HOSTNAME"

ui_input "User" "Username for the main user:" || die "Installation cancelled."
username="$INPUT_RESULT"
ask_password "User password" user_password
ask_password "Root password" root_password

# Pacman configuration
ui_menu "Pacman" "Which pacman configuration would you like to use?" \
    "1" "Local config" \
    "2" "Local cache" \
    "3" "Local cache and config" \
    "4" "vanilla.conf" \
    "5" "cachyV2.conf" \
    "6" "cachyV3.conf" \
    "7" "cachyV4.conf" \
    || die "Installation cancelled."
pacman_config_choice="$MENU_RESULT"
case $pacman_config_choice in
  1) pacman_config="-P" ;;
  2) pacman_config="-c" ;;
  3) pacman_config="-P -c" ;;
  4) pacman_config="-C ./pacmanconf/vanilla.conf" ;;
  5) pacman_config="-C ./pacmanconf/cachyV2.conf" ;;
  6) pacman_config="-C ./pacmanconf/cachyV3.conf" ;;
  7) pacman_config="-C ./pacmanconf/cachyV4.conf" ;;
  *) pacman_config="" ;;
esac

# Kernel
ui_menu "Kernel" "Choose a kernel:" \
    "1" "linux-cachyos" \
    "2" "linux-zen" \
    "3" "linux-cachyos-bore" \
    "4" "linux-cachyos-bore-lto (V3/V4 pacman config recommended)" \
    || die "Installation cancelled."
case "$MENU_RESULT" in
  1) kernel_package="linux-cachyos" ;;
  2) kernel_package="linux-zen" ;;
  3) kernel_package="linux-cachyos-bore" ;;
  4) kernel_package="linux-cachyos-bore-lto" ;;
  *) kernel_package="linux" ;;
esac

ui_menu "Zram" "Enable zram swap? (compressed RAM-backed swap, good for low-RAM systems)" \
    "no" "No" \
    "yes" "Yes" \
    || die "Installation cancelled."
enable_zram="$MENU_RESULT"

if [[ "$INSTALL_MODE" == "partitions" ]]; then
    ui_menu "Bootloader" "Choose a bootloader:" \
        "systemd-boot" "systemd-boot (simpler, faster)" \
        "grub" "GRUB efi (more features, supports multiple OSes)" \
        "grub32bitefi" "GRUB efi 32bit (cursed 32bit EFI with 64bit CPU, intel atom netbooks)" \
        "grub-bios" "GRUB bios (more features, supports multiple OSes)" \
        || die "Installation cancelled."
    bootloader="$MENU_RESULT"

    if [[ "$bootloader" == "grub" || "$bootloader" == "grub32bitefi" ]]; then
        ui_menu "GRUB" "Installation mode:" \
            "normal" "Install normally" \
            "removable" "Install with --removable flag" \
            || die "Installation cancelled."
        case "$MENU_RESULT" in
            removable) grubstate="--removable" ;;
            *) grubstate="" ;;
        esac
    else
        grubstate=""
    fi
fi

# ============================================================================
# Summary + confirmation
# ============================================================================
if [[ "$INSTALL_MODE" == "partitions" ]]; then
    SUMMARY="Disk plan:\n$(planner_summary)
Filesystem (root): $filesystem
Root encryption: $encryption (other partitions: see LUKS tags in plan)
Bootloader: $bootloader
Grub removable: ${grubstate:--}
"
else
    SUMMARY="Installation Mode: archive
Archive Output Path: $archive_output_path
"
fi
SUMMARY+="
Desktop Environment: $desktop_environment
Hostname: $HOSTNAME
Username: $username
Kernel: $kernel_package
Pacman Config: ${pacman_config:-(default)}
Zram: $enable_zram"

ui_msg "Summary" "$SUMMARY"

if [[ "$INSTALL_MODE" == "partitions" ]]; then
    CONFIRM_TEXT="Proceed with installation?\n\nThis will FORMAT the partitions marked FORMAT above. Everything on them is destroyed."
else
    CONFIRM_TEXT="Proceed with generating rootfs archive?"
fi
ui_yesno "Confirm" "$CONFIRM_TEXT" || { echo "Installation cancelled."; exit 0; }

# ============================================================================
# Execution
# ============================================================================
source ./archinstallfunctions.sh

if [[ "$INSTALL_MODE" != "archive" ]]; then
    format_all
    mount_all
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
