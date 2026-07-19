#!/bin/bash
# pve-disk-shrink.sh - Shrink a Proxmox VM disk fully offline from the host.
#
# Performs the complete shrink without GParted: resize the filesystem (ext2/3/4, NTFS
# or guest LVM), shrink the chosen partition (preserving its GUIDs), move any partitions
# after it down (order kept), shrink the backing block device (ZFS zvol / qcow2 / raw LV),
# fix the GPT backup header, and sync the VM config. Auto-discovers the storage backend
# and partition layout, lets you pick the disk and partition, and refuses to make the
# disk smaller than the data plus a chosen headroom.
#
# Usage:
#   pve-disk-shrink.sh                 interactive dialog TUI
#   pve-disk-shrink.sh --dry-run       plan only, change nothing
#   pve-disk-shrink.sh --debug         verbose trace to the logfile
#
# Requires: root on a Proxmox VE node. Tools: sgdisk, e2fsck, resize2fs, qemu-nbd,
#           qemu-img, blkid, lsblk, partx, zfs, dialog (plus lvm2 / kpartx when needed).
#
# Author: Garfieldttt (Thomas Rzen)

set -euo pipefail

# Every size and geometry value below is parsed from the English output of sgdisk,
# resize2fs, dumpe2fs, ntfsresize and lvm. Force the C locale so a localized host cannot
# silently mis-parse those strings into empty values (which would corrupt the geometry math).
export LC_ALL=C LANG=C

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
VERSION="1.3.0"
DRY_RUN=0
DEBUG=0
LOGDIR="/var/log/pve-disk-shrink"
LOGFILE="$LOGDIR/pve-disk-shrink.log"
BACKTITLE="PVE Disk Shrink v$VERSION"

# State filled in during discovery / execution (used by the cleanup trap)
GUEST_TYPE="vm"      # vm (qm) or ct (pct / LXC container)
DATASET=""           # ZFS dataset name for a container subvol volume
NBD_DEV=""            # /dev/nbdX if a qcow2 image is attached
PARTX_BASE=""         # base device we ran "partx -a" against
ACTIVE_VG=""          # guest volume group we activated and must deactivate
LVM_CFG=()            # scoped LVM options (permissive filter + our device only)
PV_TARGET_BYTES=0     # size to shrink a guest PV to (filesystem plus metadata margin)
PROTECTION_VMID=""    # VM whose protection flag we disabled and must re-enable
GAUGE_FD=""           # open write fd to the progress gauge, when one is running
GAUGE_PID=""
GAUGE_FIFO=""

# ---------------------------------------------------------------------------
# Logging / error handling
# ---------------------------------------------------------------------------
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOGFILE" 2>/dev/null || true; }

die() {
    local msg="$*"
    log "FATAL: $msg"
    cleanup
    if command -v dialog >/dev/null && [[ -t 1 || -t 2 ]]; then
        dialog --backtitle "$BACKTITLE" --title "Error" --msgbox "\n$msg" 12 72 2>/dev/tty || true
        clear
    fi
    printf 'Error: %s\n' "$msg" >&2
    exit 1
}

_on_error() {
    local rc=$? line=$BASH_LINENO cmd=$BASH_COMMAND
    # dialog cancel/ESC returns non-zero and is handled explicitly, not an error here
    [[ "$cmd" == *"dialog "* ]] && return
    log "ERR line $line rc $rc cmd: $cmd"
    die "Unexpected failure (line $line, exit $rc):\n$cmd\n\nSee $LOGFILE"
}
trap _on_error ERR

# ---------------------------------------------------------------------------
# Cleanup: always detach whatever we attached, in reverse order
# ---------------------------------------------------------------------------
cleanup() {
    trap - ERR
    # close the progress gauge if one is running
    if [[ -n "$GAUGE_FD" ]]; then
        eval "exec ${GAUGE_FD}>&-" 2>/dev/null || true
        [[ -n "$GAUGE_PID" ]] && { wait "$GAUGE_PID" 2>/dev/null || true; }
        [[ -n "$GAUGE_FIFO" && -e "$GAUGE_FIFO" ]] && rm -f "$GAUGE_FIFO"
        GAUGE_FD=""; GAUGE_PID=""; GAUGE_FIFO=""
    fi
    # re-enable the protection flag if we disabled it
    if [[ -n "$PROTECTION_VMID" ]]; then
        guest_setprot "$PROTECTION_VMID" 1 >>"$LOGFILE" 2>&1 || true
        PROTECTION_VMID=""
    fi
    if [[ -n "$ACTIVE_VG" ]]; then
        vgchange "${LVM_CFG[@]}" -an "$ACTIVE_VG" >>"$LOGFILE" 2>&1 || true
        ACTIVE_VG=""
    fi
    if [[ -n "$PARTX_BASE" ]]; then
        partx -d "$PARTX_BASE" >>"$LOGFILE" 2>&1 || true
        PARTX_BASE=""
    fi
    if [[ -n "$NBD_DEV" ]]; then
        qemu-nbd -d "$NBD_DEV" >>"$LOGFILE" 2>&1 || true
        NBD_DEV=""
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# dialog wrappers (each swallows the cancel exit code; return 1 on cancel)
# ---------------------------------------------------------------------------
d_msg()  { dialog --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" "${3:-14}" "${4:-72}" 2>/dev/tty || true; }
d_yesno(){ dialog --backtitle "$BACKTITLE" --title "$1" --yesno "$2" "${3:-14}" "${4:-72}" 2>/dev/tty; }  # 0 yes, 1 no

d_menu() { # title text menuheight tag item tag item ...  -> echoes chosen tag
    local title=$1 text=$2 h=$3; shift 3
    local out rc
    out=$(dialog --backtitle "$BACKTITLE" --title "$title" --menu "$text" $((h+8)) 78 "$h" "$@" 3>&1 1>&2 2>&3) || rc=$?
    [[ ${rc:-0} -ne 0 ]] && return 1
    printf '%s' "$out"
}

d_input() { # title text default -> echoes entered value
    local out rc
    out=$(dialog --backtitle "$BACKTITLE" --title "$1" --inputbox "$2" 10 72 "${3:-}" 3>&1 1>&2 2>&3) || rc=$?
    [[ ${rc:-0} -ne 0 ]] && return 1
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Progress gauge (background dialog fed through a fifo). Shows a live elapsed
# second counter during long steps so it is obvious the tool is not hung.
# ---------------------------------------------------------------------------
start_gauge() {
    [[ -t 1 || -t 2 ]] || return 0
    GAUGE_FIFO=$(mktemp -u /tmp/pve-disk-shrink-gauge.XXXXXX)
    mkfifo "$GAUGE_FIFO"
    dialog --backtitle "$BACKTITLE" --title "Shrinking disk" --gauge "Preparing ..." 8 74 0 <"$GAUGE_FIFO" 2>/dev/tty &
    GAUGE_PID=$!
    exec {GAUGE_FD}>"$GAUGE_FIFO"
}

# progress <percent> <message>
progress() {
    [[ -n "$GAUGE_FD" ]] || return 0
    printf 'XXX\n%s\n%s\nXXX\n' "$1" "$2" >&"$GAUGE_FD" 2>/dev/null || true
}

stop_gauge() {
    [[ -n "$GAUGE_FD" ]] || return 0
    progress 100 "Done."
    sleep 1
    eval "exec ${GAUGE_FD}>&-" 2>/dev/null || true
    [[ -n "$GAUGE_PID" ]] && { wait "$GAUGE_PID" 2>/dev/null || true; }
    [[ -n "$GAUGE_FIFO" && -e "$GAUGE_FIFO" ]] && rm -f "$GAUGE_FIFO"
    GAUGE_FD=""; GAUGE_PID=""; GAUGE_FIFO=""
}

# gauge_wait <pid> <start_pct> <end_pct> <message> : tick the gauge every second
# with elapsed time while the background pid runs, advancing within the range.
gauge_wait() {
    local pid=$1 pct=$2 ep=$3 msg=$4 t=0 rc=0
    if [[ -z "$GAUGE_FD" ]]; then wait "$pid" || rc=$?; return $rc; fi
    while kill -0 "$pid" 2>/dev/null; do
        progress "$pct" "$msg (${t}s)"
        sleep 1; t=$((t+1)); (( pct < ep-1 )) && pct=$((pct+1))
    done
    wait "$pid" || rc=$?
    progress "$ep" "$msg (${t}s)"
    return $rc
}

# ---------------------------------------------------------------------------
# Size helpers (work in bytes; align / round conservatively)
# ---------------------------------------------------------------------------
MIB=$((1024*1024))
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
roundup() { local v=$1 a=$2; echo $(( (v + a - 1) / a * a )); }   # round v up to multiple of a

# Ensure a command is available, offering to install its package first. Always asks
# before installing anything; dies if the user declines or the install fails.
ensure_pkg() {
    local cmd=$1 pkg=$2 purpose=$3
    command -v "$cmd" >/dev/null && return 0
    if [[ -t 1 || -t 2 ]]; then
        d_yesno "Install $pkg?" "$purpose needs '$cmd' from the package '$pkg', which is not installed on this host.\n\nInstall it now with apt?" \
            || die "$cmd not found. Install the $pkg package first (apt install $pkg)."
    else
        die "$cmd not found. Install the $pkg package first (apt install $pkg)."
    fi
    apt-get install -y "$pkg" >>"$LOGFILE" 2>&1 || die "apt install $pkg failed. Install it manually."
    command -v "$cmd" >/dev/null || die "$cmd still not available after installing $pkg."
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
preflight_env() {
    [[ $EUID -eq 0 ]] || die "Must run as root on a Proxmox VE node."
    command -v qm >/dev/null || die "qm not found. This must run on a Proxmox VE node."
    mkdir -p "$LOGDIR" 2>/dev/null || true
    local t missing=()
    for t in sgdisk e2fsck resize2fs qemu-nbd qemu-img blkid lsblk partx zfs dialog numfmt; do
        command -v "$t" >/dev/null || missing+=("$t")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"
    log "=== start $(date) dry_run=$DRY_RUN ==="
}

# ---------------------------------------------------------------------------
# Guest (VM via qm, or LXC container via pct) management dispatch
# ---------------------------------------------------------------------------
guest_noun()     { if [[ $GUEST_TYPE == ct ]]; then printf CT; else printf VM; fi; }
guest_config()   { if [[ $GUEST_TYPE == ct ]]; then pct config "$1"; else qm config "$1"; fi; }
guest_status()   { if [[ $GUEST_TYPE == ct ]]; then pct status "$1" 2>/dev/null | awk '{print $2}'; else qm status "$1" 2>/dev/null | awk '{print $2}'; fi; }
guest_stop()     { if [[ $GUEST_TYPE == ct ]]; then pct stop "$1"; else qm stop "$1"; fi; }
guest_start()    { if [[ $GUEST_TYPE == ct ]]; then pct start "$1"; else qm start "$1"; fi; }
guest_listsnap() { if [[ $GUEST_TYPE == ct ]]; then pct listsnapshot "$1" 2>/dev/null; else qm listsnapshot "$1" 2>/dev/null; fi; }
guest_delsnap()  { if [[ $GUEST_TYPE == ct ]]; then pct delsnapshot "$1" "$2"; else qm delsnapshot "$1" "$2"; fi; }
guest_setprot()  { if [[ $GUEST_TYPE == ct ]]; then pct set "$1" --protection "$2"; else qm set "$1" --protection "$2"; fi; }

# ---------------------------------------------------------------------------
# 1. Select a VM or container
# ---------------------------------------------------------------------------
select_guest() {
    local args=() id name status
    while read -r id name status _; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        args+=("$id" "VM  $name [$status]")
    done < <(qm list 2>/dev/null | tail -n +2)
    while read -r id status name; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        args+=("$id" "CT  $name [$status]")
    done < <(pct list 2>/dev/null | awk 'NR>1{print $1, $2, $NF}')
    [[ ${#args[@]} -gt 0 ]] || die "No VMs or containers found."
    d_menu "Select VM or container" "Choose the guest whose disk or volume you want to shrink:" 18 "${args[@]}"
}

# Echo the names of a guest's snapshots, one per line, excluding the "current" marker.
list_snapshots() {
    guest_listsnap "$1" \
        | sed -E 's/^[^A-Za-z0-9_]*//' \
        | awk 'NF{print $1}' \
        | grep -vx current || true
}

# ---------------------------------------------------------------------------
# 2. Enumerate and select a disk (a VM often has several disks)
# ---------------------------------------------------------------------------
# Echoes "key<TAB>volume<TAB>size" for every real data disk. Excludes efidisk,
# tpmstate, cloudinit and CD/DVD drives (media=cdrom) so those can never be touched.
list_disks() {
    local vmid=$1 line key rest vol size
    while IFS= read -r line; do
        key=${line%%:*}
        [[ "$key" =~ ^(scsi|virtio|sata|ide)[0-9]+$ ]] || continue
        rest=${line#*: }
        [[ "$rest" == *media=cdrom* ]] && continue
        [[ "$rest" == none* || "$rest" == *cloudinit* ]] && continue
        vol=${rest%%,*}
        [[ -n "$vol" && "$vol" != *.iso ]] || continue
        size=$(sed -n 's/.*size=\([0-9A-Za-z.]*\).*/\1/p' <<<"$rest")
        printf '%s\t%s\t%s\n' "$key" "$vol" "${size:-?}"
    done < <(qm config "$vmid")
}

# Dialog to pick which disk to shrink. Marks the boot disk so the user knows.
select_disk() {
    local vmid=$1 boot args=() key vol size tag
    boot=$(qm config "$vmid" | sed -n 's/^boot:.*order=\([^ ]*\).*/\1/p' | tr ';,' '\n\n' | head -1)
    while IFS=$'\t' read -r key vol size; do
        tag=""; [[ "$key" == "$boot" ]] && tag=" [boot]"
        args+=("$key" "$vol  ($size)$tag")
    done < <(list_disks "$vmid")
    [[ ${#args[@]} -gt 0 ]] || die "VM $vmid has no shrinkable data disks."
    d_menu "Select disk on VM $vmid" "A VM can have several disks. Pick the one to shrink.\nefidisk, tpmstate, cloudinit and CD drives are never listed." 12 "${args[@]}"
}

# Echoes "key<TAB>volume<TAB>size" for a container's rootfs and mount-point volumes.
# Skips bind mounts and device passthrough (entries with no storage:volume reference).
ct_list_volumes() {
    local id=$1 line key rest vol size
    while IFS= read -r line; do
        key=${line%%:*}
        [[ "$key" =~ ^(rootfs|mp[0-9]+)$ ]] || continue
        rest=${line#*: }
        vol=${rest%%,*}
        [[ "$vol" == *:* ]] || continue
        size=$(sed -n 's/.*size=\([0-9A-Za-z.]*\).*/\1/p' <<<"$rest")
        printf '%s\t%s\t%s\n' "$key" "$vol" "${size:-?}"
    done < <(pct config "$id")
}

# Pick which disk (VM) or volume (container) to shrink, dispatching on guest type.
select_volume() {
    local id=$1
    if [[ $GUEST_TYPE == vm ]]; then select_disk "$id"; return; fi
    local args=() key vol size
    while IFS=$'\t' read -r key vol size; do
        args+=("$key" "$vol  ($size)")
    done < <(ct_list_volumes "$id")
    [[ ${#args[@]} -gt 0 ]] || die "Container $id has no shrinkable volumes."
    d_menu "Select volume on CT $id" "Pick the rootfs or mount-point volume to shrink." 12 "${args[@]}"
}

# Dialog to pick which partition to shrink. Lists every partition with its size and
# filesystem note; only shrinkable ones (ext / NTFS / LVM) can be chosen. Runs after
# analyze (needs ALL_PARTS and SECTOR_SIZE). No prompt for whole-disk or when there is
# only a single shrinkable partition.
select_partition() {
    [[ ${NO_GPT:-0} -eq 0 ]] || return 0
    local line n s e fs shrinkable=0 has_bl=0
    for line in "${ALL_PARTS[@]}"; do
        IFS=$'\t' read -r n s e fs <<<"$line"
        fs_shrinkable "$fs" && shrinkable=$((shrinkable+1))
        [[ "$fs" == BitLocker ]] && has_bl=1
    done
    # On a BitLocker disk the real target (C:) is locked and the only shrinkable thing is
    # usually the tiny recovery partition, which nobody wants. Show the hint and force a
    # conscious choice instead of silently defaulting to recovery.
    (( has_bl )) && bitlocker_note
    [[ $shrinkable -ge 1 ]] || die "No shrinkable partition on this disk."
    [[ $shrinkable -eq 1 && $has_bl -eq 0 ]] && return 0
    while true; do
        local args=() sizeh sel selfs=""
        for line in "${ALL_PARTS[@]}"; do
            IFS=$'\t' read -r n s e fs <<<"$line"
            sizeh=$(human $(( (e - s + 1) * SECTOR_SIZE )))
            args+=("$n" "part$n  $sizeh  $(fs_note "$fs")")
        done
        sel=$(dialog --backtitle "$BACKTITLE" --title "Select partition on $DISK_KEY" --default-item "$LAST_N" \
            --menu "Pick the partition to shrink. Partitions after it keep their order and are moved down." \
            20 82 12 "${args[@]}" 3>&1 1>&2 2>&3) || { detach_disk; clear; exit 0; }
        for line in "${ALL_PARTS[@]}"; do IFS=$'\t' read -r n s e fs <<<"$line"; [[ "$n" == "$sel" ]] && selfs=$fs; done
        if fs_shrinkable "$selfs"; then choose_partition "$sel"; return 0; fi
        if [[ "$selfs" == BitLocker ]]; then
            bitlocker_note
        else
            d_msg "Not shrinkable" "part$sel is $(fs_note "$selfs") and cannot be shrunk. Pick another partition."
        fi
    done
}

# ---------------------------------------------------------------------------
# Discover backend for a chosen disk key
# ---------------------------------------------------------------------------
# Sets: DISK_KEY DISK_VOL DISK_PATH BACKEND (zvol|qcow2|rawlv) ZVOL VOLBLK CFG_SIZE
discover_disk() {
    local vmid=$1 diskkey=$2 cfg
    cfg=$(qm config "$vmid")
    [[ "$diskkey" == efidisk* || "$diskkey" == tpmstate* ]] && die "'$diskkey' is not a data disk and must never be shrunk."
    DISK_KEY=$diskkey
    DISK_VOL=$(sed -n "s/^${DISK_KEY}: \([^,]*\).*/\1/p" <<<"$cfg")
    [[ -n "$DISK_VOL" ]] || die "Could not read volume for $DISK_KEY."
    CFG_SIZE=$(sed -n "s/^${DISK_KEY}:.*size=\([0-9A-Za-z]*\).*/\1/p" <<<"$cfg")
    DISK_PATH=$(pvesm path "$DISK_VOL")
    [[ -n "$DISK_PATH" ]] || die "pvesm path failed for $DISK_VOL."

    if [[ "$DISK_PATH" == /dev/zvol/* ]]; then
        BACKEND=zvol
        ZVOL=${DISK_PATH#/dev/zvol/}
        VOLBLK=$(numfmt --from=iec "$(zfs get -H -o value volblocksize "$ZVOL")")
    elif [[ "$DISK_PATH" == *.qcow2 || "$(qemu-img info --output=json "$DISK_PATH" 2>/dev/null | grep -o '"format": "qcow2"')" ]]; then
        BACKEND=qcow2
    elif [[ -b "$DISK_PATH" ]]; then
        BACKEND=rawlv
    else
        die "Unsupported disk path: $DISK_PATH"
    fi
    log "discover vmid=$vmid key=$DISK_KEY vol=$DISK_VOL path=$DISK_PATH backend=$BACKEND cfgsize=${CFG_SIZE:-?}"
}

# Discover the backend for a chosen container volume (rootfs or mpN). Container volumes hold
# a filesystem directly (no partition table). Sets the same globals as discover_disk plus
# DATASET for a ZFS subvol. BACKEND is one of: rawfile (raw image on a dir), ctlvm (LV) or
# zfssubvol (ZFS dataset with a refquota).
discover_ct() {
    local id=$1 key=$2 cfg
    cfg=$(pct config "$id")
    DISK_KEY=$key
    DISK_VOL=$(sed -n "s/^${key}: \([^,]*\).*/\1/p" <<<"$cfg")
    [[ -n "$DISK_VOL" ]] || die "Could not read volume for $key."
    CFG_SIZE=$(sed -n "s/^${key}:.*size=\([0-9A-Za-z.]*\).*/\1/p" <<<"$cfg")
    DISK_PATH=$(pvesm path "$DISK_VOL")
    [[ -n "$DISK_PATH" ]] || die "pvesm path failed for $DISK_VOL."
    local volname=${DISK_VOL#*:}
    if [[ "$volname" == subvol-* || -d "$DISK_PATH" ]]; then
        BACKEND=zfssubvol
        DATASET=$(zfs list -H -o name,mountpoint -t filesystem 2>/dev/null | awk -v m="$DISK_PATH" '$2==m{print $1}')
        [[ -n "$DATASET" ]] || die "Could not resolve the ZFS dataset for $DISK_VOL (path $DISK_PATH)."
    elif [[ -b "$DISK_PATH" ]]; then
        BACKEND=ctlvm
    elif [[ -f "$DISK_PATH" ]]; then
        BACKEND=rawfile
    else
        die "Unsupported container volume path: $DISK_PATH"
    fi
    log "discover ct id=$id key=$key vol=$DISK_VOL path=$DISK_PATH backend=$BACKEND dataset=${DATASET:-none} cfgsize=${CFG_SIZE:-?}"
}

# ---------------------------------------------------------------------------
# 3. Attach / detach the disk as a block device with partition children
# ---------------------------------------------------------------------------
# Sets BASE (block device exposing the partition table)
attach_disk() {
    case "$BACKEND" in
        zvol)
            BASE=$DISK_PATH
            partx -a "$BASE" >>"$LOGFILE" 2>&1 || true
            PARTX_BASE=$BASE
            ;;
        rawlv)
            ensure_pkg kpartx kpartx "The raw-LV storage backend"
            BASE=$DISK_PATH
            partx -a "$BASE" >>"$LOGFILE" 2>&1 || true
            PARTX_BASE=$BASE
            ;;
        rawfile|ctlvm)
            # Container volume: a filesystem sits directly on the file/LV, no partition table.
            BASE=$DISK_PATH
            ;;
        qcow2)
            modprobe nbd max_part=16 2>>"$LOGFILE" || true
            local n
            for n in $(seq 0 15); do
                [[ -e "/sys/block/nbd$n/pid" ]] && continue
                if qemu-nbd -c "/dev/nbd$n" "$DISK_PATH" >>"$LOGFILE" 2>&1; then
                    NBD_DEV="/dev/nbd$n"; break
                fi
            done
            [[ -n "$NBD_DEV" ]] || die "No free nbd device to attach the qcow2 image."
            BASE=$NBD_DEV
            ;;
    esac
    udevadm settle 2>/dev/null || true
    sleep 1
    log "attach backend=$BACKEND base=$BASE nbd=${NBD_DEV:-none}"
}

# Echo the device node for partition number $1 on $BASE
partdev() {
    local n=$1
    case "$BACKEND" in
        zvol)  echo "${BASE}-part${n}" ;;
        qcow2) echo "${BASE}p${n}" ;;
        rawlv) [[ -e "${BASE}p${n}" ]] && echo "${BASE}p${n}" || echo "${BASE}${n}" ;;
    esac
}

detach_disk() { cleanup; }

# Read partition number $1 into LAST_N / LAST_START / LAST_END / LAST_TYPE /
# LAST_GUID / LAST_NAME / LAST_DEV / LAST_FS.
_read_part() {
    local n=$1 info
    info=$(sgdisk -i "$n" "$BASE")
    LAST_N=$n
    LAST_START=$(sed -n 's/First sector: \([0-9]*\).*/\1/p' <<<"$info")
    LAST_END=$(sed -n 's/Last sector: \([0-9]*\).*/\1/p' <<<"$info")
    LAST_TYPE=$(sed -n 's/Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p' <<<"$info")
    LAST_GUID=$(sed -n 's/Partition unique GUID: \([0-9A-Fa-f-]*\).*/\1/p' <<<"$info")
    LAST_NAME=$(sed -n "s/Partition name: '\(.*\)'/\1/p" <<<"$info")
    LAST_ATTRS=$(sed -n 's/.*Attribute flags: *\([0-9A-Fa-f]*\).*/\1/p' <<<"$info")
    LAST_DEV=$(partdev "$n")
    LAST_FS=$(blkid -o value -s TYPE "$LAST_DEV" 2>/dev/null || echo "")
    # Bad geometry (e.g. a localized sgdisk or an unexpected layout) must stop us before any
    # arithmetic runs on empty values and corrupts the partition table.
    [[ "$LAST_START" =~ ^[0-9]+$ && "$LAST_END" =~ ^[0-9]+$ ]] \
        || die "Could not read partition $n geometry from sgdisk (start='$LAST_START' end='$LAST_END')."
}

# Restore GPT attribute flags on a freshly recreated partition. sgdisk -n drops them, so
# Windows Recovery (bits 63/0) and BIOS-GPT bios_grub (bit 2) would otherwise lose their
# flags. The new partition starts with a zero attribute field, so OR-ing the saved mask sets
# exactly the original bits. Non-fatal: a completed shrink must not be undone if a flag does
# not stick.
apply_attrs() {   # partnum hexmask
    local n=$1 attrs=$2
    [[ "$attrs" =~ ^[0-9A-Fa-f]+$ && ! "$attrs" =~ ^0+$ ]] || return 0
    sgdisk "--attributes=${n}:or:${attrs}" "$BASE" >>"$LOGFILE" 2>&1 \
        || log "warning: could not restore attribute flags $attrs on partition $n"
}

# A filesystem this tool can shrink in place.
fs_shrinkable() { case "$1" in ext2|ext3|ext4|ntfs|LVM2_member) return 0 ;; *) return 1 ;; esac; }

# Human note for a partition filesystem in the chooser menu.
fs_note() {
    case "$1" in
        ext2|ext3|ext4)  echo "ext" ;;
        ntfs)            echo "NTFS" ;;
        LVM2_member)     echo "LVM" ;;
        swap)            echo "swap (not shrinkable)" ;;
        vfat)            echo "FAT/ESP (not shrinkable)" ;;
        xfs)             echo "XFS (cannot shrink)" ;;
        BitLocker)       echo "BitLocker (encrypted, cannot shrink)" ;;
        "")              echo "no filesystem (reserved)" ;;
        *)               echo "$1 (not shrinkable)" ;;
    esac
}

# A friendly one-line name for the disk's partition scheme, shown in the confirm summary so
# the user can see the tool recognised the layout. Runs after analyze (needs ALL_PARTS).
classify_layout() {
    [[ ${NO_GPT:-0} -eq 1 ]] && { echo "whole-disk ${LAST_FS:-unknown} (no partition table)"; return; }
    [[ $GUEST_LVM -eq 1 ]] && { echo "Linux LVM on GPT"; return; }
    local line fs ntfs=0 ext=0 xfs=0 esp=0 bl=0
    for line in "${ALL_PARTS[@]}"; do
        IFS=$'\t' read -r _ _ _ fs <<<"$line"
        case "$fs" in
            ntfs) ntfs=1 ;; ext2|ext3|ext4) ext=1 ;; xfs) xfs=1 ;;
            vfat) esp=1 ;; BitLocker) bl=1 ;;
        esac
    done
    if   (( ntfs || bl )); then echo "Windows (NTFS on GPT)"
    elif (( xfs ));        then echo "Linux XFS on GPT"
    elif (( ext && esp )); then echo "Linux ext (UEFI/GPT)"
    elif (( ext ));        then echo "Linux ext (GPT)"
    else echo "GPT"; fi
}

# Explain how to shrink a BitLocker-encrypted volume (only Windows can do it), shown
# instead of a bare refusal because the encrypted C: is usually what the user wants.
bitlocker_note() {
    [[ -t 1 || -t 2 ]] || return 0
    d_msg "BitLocker encrypted volume" "This partition is BitLocker-encrypted, so it cannot be shrunk offline from the host. Two ways to do it:\n\n A) Shrink it in Windows: Disk Management (\"Shrink Volume\") is BitLocker-aware. Then re-run this tool to reclaim the freed space at the device level (move any trailing partition down and shrink the disk).\n\n B) Turn BitLocker off in Windows first (manage-bde -off <drive>, wait until decryption finishes). The volume is then plain NTFS and this tool can shrink it directly. Re-enable BitLocker afterwards if you want.\n\nCaution is advised: make a backup before either way." 22 78
}

# Fill ALL_PARTS with one line per GPT partition: "num<TAB>start<TAB>end<TAB>fs".
scan_parts() {
    ALL_PARTS=()
    local n s e d fs
    while read -r n s e; do
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        d=$(partdev "$n"); fs=$(blkid -o value -s TYPE "$d" 2>/dev/null || echo "")
        ALL_PARTS+=("$n"$'\t'"$s"$'\t'"$e"$'\t'"$fs")
    done < <(sgdisk -p "$BASE" 2>/dev/null | awk '/^ *[0-9]+ /{print $1, $2, $3}')
}

# Set the partition to shrink and compute the trailing partitions (those that start
# after it), ascending by start. Sets LAST_* (via _read_part), GUEST_LVM and TRAIL
# (array of "num:start:end:fs").
choose_partition() {
    _read_part "$1"
    [[ "$LAST_FS" == LVM2_member ]] && GUEST_LVM=1 || GUEST_LVM=0
    TRAIL=()
    local line n s e fs
    for line in "${ALL_PARTS[@]}"; do
        IFS=$'\t' read -r n s e fs <<<"$line"
        (( s > LAST_START )) && TRAIL+=("$n:$s:$e:$fs")
    done
    ((${#TRAIL[@]})) && mapfile -t TRAIL < <(printf '%s\n' "${TRAIL[@]}" | sort -t: -k2 -n)
    log "choose_partition n=$LAST_N fs=$LAST_FS trailing=${TRAIL[*]:-none}"
}

# ---------------------------------------------------------------------------
# 4. Analyze partition layout
# ---------------------------------------------------------------------------
# Sets: SECTORS SECTOR_SIZE NO_GPT GUEST_LVM ALL_PARTS, and (via choose_partition on the
#       default target) LAST_N LAST_START LAST_END LAST_TYPE LAST_GUID LAST_NAME LAST_FS
#       LAST_DEV TRAIL.
analyze() {
    if [[ -b "$BASE" ]]; then
        SECTOR_SIZE=$(blockdev --getss "$BASE")
        SECTORS=$(blockdev --getsz "$BASE")
    else
        # container raw image file: no block device, size comes from the file itself
        SECTOR_SIZE=512
        SECTORS=$(( $(stat -c%s "$BASE") / 512 ))
    fi
    NO_GPT=0; GUEST_LVM=0; ALL_PARTS=(); TRAIL=(); TRAILING_ONLY=0; LVM_COMPACT=0

    # Whole-disk case: a filesystem or LVM PV sits directly on the device, no
    # partition table. Common for secondary data disks. Detect and handle without
    # any sgdisk / GPT step.
    local basefs; basefs=$(blkid -o value -s TYPE "$BASE" 2>/dev/null || echo "")
    local pttype; pttype=$(blkid -o value -s PTTYPE "$BASE" 2>/dev/null || echo "")
    if [[ -n "$basefs" && "$basefs" != "" && -z "$pttype" ]]; then
        NO_GPT=1
        LAST_DEV=$BASE
        LAST_FS=$basefs
        [[ "$LAST_FS" == LVM2_member ]] && GUEST_LVM=1
        log "analyze whole-disk fs=$LAST_FS on $BASE (no partition table)"
        return 0
    fi
    if [[ "$pttype" == dos ]]; then
        die "Disk $DISK_KEY uses an MBR (msdos) partition table, which this tool does not shrink.\n\nMBR is common on BIOS-installed Debian and Windows VMs. Options:\n - Convert the disk to GPT (e.g. gdisk 'w', or sgdisk --mbrtogpt) and re-run this tool, or\n - Shrink it with GParted from a live ISO.\n\nNothing was changed."
    fi
    [[ "$pttype" == gpt || -z "$pttype" ]] || die "Disk $DISK_KEY has a '$pttype' partition table; only GPT and whole-disk are supported. Nothing was changed."

    # GPT case: scan all partitions and default to the largest shrinkable one. The user
    # can override this in select_partition.
    scan_parts
    [[ ${#ALL_PARTS[@]} -gt 0 ]] || die "No GPT partitions and no whole-disk filesystem found on $BASE."
    local line n s e fs best="" bestsz=0
    for line in "${ALL_PARTS[@]}"; do
        IFS=$'\t' read -r n s e fs <<<"$line"
        fs_shrinkable "$fs" || continue
        if (( e - s > bestsz )); then bestsz=$((e - s)); best=$n; fi
    done
    if [[ -z "$best" ]]; then
        for line in "${ALL_PARTS[@]}"; do IFS=$'\t' read -r n s e fs <<<"$line"; [[ "$fs" == BitLocker ]] && { bitlocker_note; break; }; done
        die "No shrinkable filesystem found on $BASE (found: $(for l in "${ALL_PARTS[@]}"; do IFS=$'\t' read -r _ _ _ f <<<"$l"; printf '%s ' "${f:-none}"; done))."
    fi
    choose_partition "$best"
    log "analyze default_n=$LAST_N fs=$LAST_FS start=$LAST_START end=$LAST_END lvm=$GUEST_LVM parts=${#ALL_PARTS[@]}"
}

# Make sure the target filesystem is clean before touching it. A read-only check
# detects errors first; if there are any, the user is asked whether to repair them (a
# shrink on a dirty filesystem is unsafe). A writable e2fsck -f always runs afterwards
# because resize2fs and lvreduce refuse to run without a fresh forced check.
# e2fsck exit codes: 0 clean, 1/2 corrected, >=4 not fully corrected.
ensure_clean_fs() {
    local dev=$1 rc=0
    e2fsck -fn "$dev" >>"$LOGFILE" 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        if [[ -t 1 || -t 2 ]]; then
            d_yesno "Filesystem errors found" "e2fsck reports errors on the filesystem to shrink:\n\n  $dev\n\nA disk cannot be shrunk safely while its filesystem has errors.\n\nRun e2fsck now to repair it?" \
                || die "Filesystem on $dev has errors and was not repaired. Not shrinking."
        fi
        # non-interactive (test harness) falls through and repairs automatically
    fi
    # Always run a writable forced check: repairs approved errors, and satisfies
    # resize2fs / lvreduce which require a recent e2fsck -f. On a clean fs this makes
    # no changes.
    local r2=0
    e2fsck -fy "$dev" >>"$LOGFILE" 2>&1 || r2=$?
    (( r2 >= 4 )) && die "e2fsck could not fully repair $dev (exit $r2). Not shrinking; inspect $LOGFILE."
    log "ensure_clean_fs $dev (detect rc=$rc, fix exit=$r2)"
}

# ---------------------------------------------------------------------------
# 5. Compute minimum data size and safe target
# ---------------------------------------------------------------------------
# Activate the guest volume group and scope every LVM command to just this PV. The host
# global_filter usually rejects zvols (/dev/zd*), so a permissive filter plus an explicit
# --devices list means we neither depend on the host filter nor ever touch another VG.
# use_lvmpolld=0 makes pvmove block in the foreground until 100% (see do_shrink). Sets
# LVM_CFG, ACTIVE_VG, GUEST_PV, the PV geometry (PV_EXTENT, PV_PESTART, PV_ALLOC) and
# PV_USED_BYTES (smallest the PV can be with no filesystem shrink), plus LVM_HAS_EXT (an
# ext LV exists that we could shrink to go smaller) and LVM_FS_LIST for the summary.
lvm_prepare() {
    GUEST_PV=$LAST_DEV
    local pvreal; pvreal=$(readlink -f "$GUEST_PV")
    LVM_CFG=(--config 'devices/global_filter=["a|.*|"] global/use_lvmpolld=0' --devices "$pvreal")
    ACTIVE_VG=$(pvs "${LVM_CFG[@]}" --noheadings -o vg_name "$GUEST_PV" 2>>"$LOGFILE" | tr -d ' ')
    [[ -n "$ACTIVE_VG" ]] || die "Could not find a volume group on $GUEST_PV."
    vgchange "${LVM_CFG[@]}" -ay "$ACTIVE_VG" >>"$LOGFILE" 2>&1 || die "Could not activate guest VG $ACTIVE_VG."
    PV_EXTENT=$(vgs "${LVM_CFG[@]}" --noheadings --units b --nosuffix -o vg_extent_size "$ACTIVE_VG" 2>>"$LOGFILE" | tr -d ' ')
    PV_PESTART=$(pvs "${LVM_CFG[@]}" --noheadings --units b --nosuffix -o pe_start "$GUEST_PV" 2>>"$LOGFILE" | tr -d ' ')
    PV_ALLOC=$(pvs "${LVM_CFG[@]}" --noheadings -o pv_pe_alloc_count "$GUEST_PV" 2>>"$LOGFILE" | tr -d ' ')
    [[ "$PV_EXTENT" =~ ^[0-9]+$ && "$PV_PESTART" =~ ^[0-9]+$ && "$PV_ALLOC" =~ ^[0-9]+$ ]] \
        || die "Could not read LVM geometry (extent=$PV_EXTENT pe_start=$PV_PESTART alloc=$PV_ALLOC)."
    PV_USED_BYTES=$(( PV_PESTART + PV_ALLOC * PV_EXTENT ))
    LVM_HAS_EXT=0; LVM_FS_LIST=""
    local lv dev fstype
    while read -r lv; do
        [[ -n "$lv" ]] || continue
        dev="/dev/$ACTIVE_VG/$lv"
        fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null || echo "")
        case "$fstype" in ext2|ext3|ext4) LVM_HAS_EXT=1 ;; esac
        LVM_FS_LIST+="${lv}(${fstype:-none}) "
    done < <(lvs "${LVM_CFG[@]}" --noheadings -o lv_name "$ACTIVE_VG" 2>>"$LOGFILE" | awk '{print $1}')
    log "lvm_prepare vg=$ACTIVE_VG extent=$PV_EXTENT pe_start=$PV_PESTART alloc=$PV_ALLOC used=$PV_USED_BYTES has_ext=$LVM_HAS_EXT fs=[$LVM_FS_LIST]"
}

# Deep guest-LVM path only: to go BELOW the used size we must shrink a filesystem. Pick the
# largest ext LV, and set MIN_FS_BYTES, FS_TARGET_DEV and LV_TARGET_CUR (its current size).
# XFS LVs cannot shrink, so if none is ext we refuse and point at the compact option.
compute_min_lv() {
    local lv dev fstype best_dev="" best_size=0 size
    while read -r lv size; do
        dev="/dev/$ACTIVE_VG/$lv"
        fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null || echo "")
        case "$fstype" in ext2|ext3|ext4) ;; *) continue ;; esac
        if (( size > best_size )); then best_size=$size; best_dev=$dev; fi
    done < <(lvs "${LVM_CFG[@]}" --noheadings --units b --nosuffix -o lv_name,lv_size "$ACTIVE_VG" 2>>"$LOGFILE" | awk '{print $1, $2}')
    [[ -n "$best_dev" ]] || die "No ext filesystem in VG $ACTIVE_VG can be shrunk (XFS cannot shrink). Use the compact option to reclaim the volume group's free space instead."
    FS_TARGET_DEV=$best_dev; LV_TARGET_CUR=$best_size
    ensure_clean_fs "$FS_TARGET_DEV"
    local minblk blksz
    minblk=$(resize2fs -P "$FS_TARGET_DEV" 2>/dev/null | awk -F': ' '/Estimated minimum size/{print $2}')
    blksz=$(dumpe2fs -h "$FS_TARGET_DEV" 2>/dev/null | awk -F': *' '/Block size/{print $2}')
    [[ -n "$minblk" && -n "$blksz" ]] || die "Could not estimate the minimum filesystem size."
    MIN_FS_BYTES=$(( minblk * blksz ))
    log "compute_min_lv target=$FS_TARGET_DEV cur=$LV_TARGET_CUR min_fs_bytes=$MIN_FS_BYTES ($(human "$MIN_FS_BYTES"))"
}

# Plan the resulting geometry for a guest-LVM shrink from a desired PV size (bytes). Rounds
# the PV up to a whole extent, then derives the partition end (or whole-disk size) and the
# device size. Sets PV_TARGET_BYTES NEW_LAST_END NEW_DEV_BYTES TRAIL_NEW. do_shrink later
# recomputes the exact PV size from the real post-pvmove geometry; this is the plan/summary.
plan_lvm() {
    local pv=$1 ext=$PV_EXTENT ps=$PV_PESTART
    local need_ext=$(( (pv - ps + ext - 1) / ext )); (( need_ext < 1 )) && need_ext=1
    PV_TARGET_BYTES=$(( ps + need_ext * ext ))
    if [[ ${NO_GPT:-0} -eq 1 ]]; then
        local d; d=$(roundup "$PV_TARGET_BYTES" "$MIB")
        [[ "$BACKEND" == zvol ]] && d=$(roundup "$d" "$VOLBLK")
        NEW_DEV_BYTES=$d; NEW_LAST_END=0; TRAIL_NEW=()
    else
        local align=$(( MIB / SECTOR_SIZE )) psec
        psec=$(( (PV_TARGET_BYTES + SECTOR_SIZE - 1) / SECTOR_SIZE ))
        NEW_LAST_END=$(( LAST_START + psec - 1 ))
        NEW_LAST_END=$(( ( (NEW_LAST_END + align) / align ) * align - 1 ))
        place_trailing
    fi
    log "plan_lvm pv_target=$PV_TARGET_BYTES part_end=${NEW_LAST_END:-na} dev=$NEW_DEV_BYTES compact=${LVM_COMPACT:-0}"
}

# Determines the minimum size of the chosen filesystem (ext via resize2fs -P, NTFS via
# ntfsresize --info) and sets MIN_FS_BYTES (data floor) and FS_TARGET_DEV. Non-LVM only;
# guest LVM is handled by lvm_prepare / compute_min_lv.
compute_min() {
    GUEST_PV=""
    case "$LAST_FS" in
        ext2|ext3|ext4|ntfs) FS_TARGET_DEV=$LAST_DEV ;;
        xfs)        die "Partition $LAST_DEV is XFS and cannot be shrunk. Reclaim only the free space after it (the trailing-only option) instead." ;;
        BitLocker)  bitlocker_note; die "BitLocker volume on $LAST_DEV not shrunk (encrypted; see the note)." ;;
        "")         die "Could not detect a filesystem on $LAST_DEV." ;;
        *)          die "Unsupported filesystem '$LAST_FS' on $LAST_DEV (supported: ext2/3/4, NTFS, guest LVM)." ;;
    esac

    if [[ "$LAST_FS" == ntfs ]]; then
        ntfs_prepare "$FS_TARGET_DEV"        # dep check + clean-state guard + MIN_FS_BYTES
    else
        ensure_clean_fs "$FS_TARGET_DEV"
        local minblk blksz
        minblk=$(resize2fs -P "$FS_TARGET_DEV" 2>/dev/null | awk -F': ' '/Estimated minimum size/{print $2}')
        blksz=$(dumpe2fs -h "$FS_TARGET_DEV" 2>/dev/null | awk -F': *' '/Block size/{print $2}')
        [[ -n "$minblk" && -n "$blksz" ]] || die "Could not estimate the minimum filesystem size."
        MIN_FS_BYTES=$(( minblk * blksz ))
    fi
    log "compute_min target=$FS_TARGET_DEV fs=$LAST_FS min_fs_bytes=$MIN_FS_BYTES ($(human "$MIN_FS_BYTES"))"
}

# NTFS: ensure ntfsresize is available and the volume is cleanly shut down, and set
# MIN_FS_BYTES from ntfsresize --info.
ntfs_prepare() {
    local dev=$1
    ensure_pkg ntfsresize ntfs-3g "Shrinking NTFS"
    local info; info=$(ntfsresize --info --force "$dev" 2>&1); echo "$info" >>"$LOGFILE"
    if grep -qiE 'hibernat|scheduled|is dirty|refused to mount|read-only|please boot|chkdsk' <<<"$info"; then
        die "The NTFS volume on $dev is not cleanly shut down (hibernation / fast startup / pending check). Boot Windows, disable Fast Startup, shut down fully, then retry."
    fi
    local minb
    minb=$(grep -iE 'might resize at' <<<"$info" | grep -oE '[0-9]+' | head -1)
    [[ -n "$minb" ]] || die "Could not read the NTFS minimum size from ntfsresize (see $LOGFILE)."
    MIN_FS_BYTES=$minb
}

# Given a chosen filesystem size (bytes), compute the resulting device size (bytes),
# honouring partition start offset, trailing swap, GPT reserve, alignment and backend
# granularity. Sets: NEW_FS_BYTES NEW_LAST_END NEW_DEV_BYTES TRAIL_NEW PV_TARGET_BYTES
plan_sizes() {
    local fs_bytes=$1
    NEW_FS_BYTES=$(roundup "$fs_bytes" "$MIB")

    # Whole-disk (no partition table): device only needs to hold the fs/PV.
    PV_TARGET_BYTES=0
    if [[ ${NO_GPT:-0} -eq 1 ]]; then
        local dev=$NEW_FS_BYTES
        if (( GUEST_LVM == 1 )); then dev=$(( NEW_FS_BYTES + 40*MIB )); PV_TARGET_BYTES=$dev; fi
        dev=$(roundup "$dev" "$MIB")
        [[ "$BACKEND" == zvol ]] && dev=$(roundup "$dev" "$VOLBLK")
        NEW_DEV_BYTES=$dev; NEW_LAST_END=0; TRAIL_NEW=()
        log "plan_sizes whole-disk fs=$NEW_FS_BYTES dev=$NEW_DEV_BYTES pv=$PV_TARGET_BYTES"
        return 0
    fi

    # partition must hold the filesystem; for guest LVM the PV partition holds the VG
    # plus its metadata, so add a margin the PV can be resized into.
    local part_bytes=$NEW_FS_BYTES
    if (( GUEST_LVM == 1 )); then part_bytes=$(( NEW_FS_BYTES + 40*MIB )); PV_TARGET_BYTES=$part_bytes; fi
    NEW_PART_SECTORS=$(( (part_bytes + SECTOR_SIZE - 1) / SECTOR_SIZE ))
    # align partition end to 1 MiB boundary
    local align_sec=$(( MIB / SECTOR_SIZE ))
    NEW_LAST_END=$(( LAST_START + NEW_PART_SECTORS - 1 ))
    NEW_LAST_END=$(( ( (NEW_LAST_END + align_sec) / align_sec ) * align_sec - 1 ))
    place_trailing
    log "plan_sizes fs=$NEW_FS_BYTES part_end=$NEW_LAST_END trailing=${TRAIL_NEW[*]:-none} dev=$NEW_DEV_BYTES"
}

# From the current NEW_LAST_END, place every trailing partition right after the shrunk
# one (order and size kept) and size the device. Sets TRAIL_NEW (num:oldstart:oldend:
# newstart:newend:fs) and NEW_DEV_BYTES.
place_trailing() {
    local align_sec=$(( MIB / SECTOR_SIZE )) end_after=$NEW_LAST_END t num os oe fs sz ns ne
    TRAIL_NEW=()
    for t in "${TRAIL[@]:-}"; do
        [[ -n "$t" ]] || continue
        IFS=: read -r num os oe fs <<<"$t"
        sz=$(( oe - os + 1 ))
        ns=$(( ( (end_after / align_sec) + 1 ) * align_sec ))   # next 1 MiB boundary after prev
        ne=$(( ns + sz - 1 ))
        TRAIL_NEW+=("$num:$os:$oe:$ns:$ne:$fs")
        end_after=$ne
    done
    local dev_bytes=$(( (end_after + 34) * SECTOR_SIZE ))     # + GPT backup
    dev_bytes=$(roundup "$dev_bytes" "$MIB")
    [[ "$BACKEND" == zvol ]] && dev_bytes=$(roundup "$dev_bytes" "$VOLBLK")
    NEW_DEV_BYTES=$dev_bytes
}

# Free space (bytes) after the physically-last partition — reclaimable by simply cutting
# the device down to that partition's end, touching no filesystem, partition or LVM.
# Sets DISK_LAST_END (sector) and TRAIL_FREE_BYTES.
compute_trailing_free() {
    DISK_LAST_END=0; TRAIL_FREE_BYTES=0
    [[ ${NO_GPT:-0} -eq 0 ]] || return 0
    local line n s e fs
    for line in "${ALL_PARTS[@]}"; do
        IFS=$'\t' read -r n s e fs <<<"$line"
        (( e > DISK_LAST_END )) && DISK_LAST_END=$e
    done
    local free_sec=$(( SECTORS - 1 - DISK_LAST_END - 34 ))   # keep room for the GPT backup
    (( free_sec > 0 )) && TRAIL_FREE_BYTES=$(( free_sec * SECTOR_SIZE ))
    log "compute_trailing_free last_end=$DISK_LAST_END free=$TRAIL_FREE_BYTES"
}

# Plan a shrink that only reclaims the trailing free space: the device is cut down to the
# last partition's end. No filesystem, partition or LVM is touched, so it is safe on any
# layout (XFS, multi-LV LVM, ...). Sets TRAILING_ONLY and the size globals do_shrink needs.
plan_trailing_only() {
    TRAILING_ONLY=1; TRAIL_NEW=()
    NEW_LAST_END=$DISK_LAST_END
    local dev; dev=$(( (DISK_LAST_END + 34) * SECTOR_SIZE ))
    dev=$(roundup "$dev" "$MIB")
    [[ "$BACKEND" == zvol ]] && dev=$(roundup "$dev" "$VOLBLK")
    NEW_DEV_BYTES=$dev; NEW_FS_BYTES=0; MIN_FS_BYTES=0
    log "plan_trailing_only dev=$NEW_DEV_BYTES"
}

# Ask whether to only reclaim the trailing free space (safe) or shrink the partition's
# filesystem to get more (advanced). Sets SHRINK_MODE=trailing|partition; 1 on cancel.
ask_mode() {
    local cur=$(( SECTORS * SECTOR_SIZE )) db choice
    db=$(( (DISK_LAST_END + 34) * SECTOR_SIZE )); db=$(roundup "$db" "$MIB")
    [[ "$BACKEND" == zvol ]] && db=$(roundup "$db" "$VOLBLK")
    choice=$(d_menu "How to shrink" \
        "There is $(human "$TRAIL_FREE_BYTES") of free space after the last partition on $DISK_KEY.\n\nHow do you want to shrink it?" 6 \
        trailing  "Reclaim that free space only  ($(human "$cur") -> $(human "$db"))  [safe, no filesystem change]" \
        partition "Shrink the last partition's filesystem to reclaim more  [advanced]") || return 1
    SHRINK_MODE=$choice
}

# Guest-LVM mode chooser. Offers, in increasing invasiveness: trailing-only (cut the disk
# after the LVM partition, LVM untouched), compact (pvmove the VG's free space out and shrink
# the PV, no filesystem touched -- works with XFS), and shrinkfs (also reduce an ext LV to go
# below the used size). Sets SHRINK_MODE; returns 1 on cancel.
ask_lvm_mode() {
    local cur=$(( SECTORS * SECTOR_SIZE )) args=() choice
    if [[ ${NO_GPT:-0} -eq 0 ]] && (( TRAIL_FREE_BYTES >= 1024*MIB )); then
        local db=$(( (DISK_LAST_END + 34) * SECTOR_SIZE )); db=$(roundup "$db" "$MIB")
        [[ "$BACKEND" == zvol ]] && db=$(roundup "$db" "$VOLBLK")
        args+=(trailing "Reclaim only the free space AFTER the LVM partition ($(human "$cur") -> $(human "$db"))  [safest, LVM untouched]")
    fi
    args+=(compact "Compact the volume group and reclaim its free space too  [no filesystem touched, XFS-safe]")
    (( LVM_HAS_EXT )) && args+=(shrinkfs "Also shrink an ext filesystem to go below the used size  [advanced]")
    choice=$(d_menu "How to shrink LVM disk $DISK_KEY" \
        "Volume group: $ACTIVE_VG\nVolumes: $LVM_FS_LIST\nUsed by the VG: $(human "$PV_USED_BYTES")\n\nChoose how to shrink it:" 6 "${args[@]}") || return 1
    SHRINK_MODE=$choice
}

# Compact plan: shrink the PV down to the used size (pvmove + pvresize in do_shrink), no
# filesystem is resized. Safe for any filesystem inside the VG, including XFS.
plan_lvm_compact() {
    LVM_COMPACT=1
    plan_lvm "$PV_USED_BYTES"
    MIN_FS_BYTES=$PV_USED_BYTES; NEW_FS_BYTES=0
}

# ---------------------------------------------------------------------------
# 6. Ask for target size (headroom presets or manual)
# ---------------------------------------------------------------------------
# Returns chosen filesystem size in bytes via CHOSEN_FS_BYTES
ask_target() {
    local floor=$MIN_FS_BYTES pct choice
    local mtext="Data in use (filesystem minimum): $(human "$floor")\n\nChoose how much larger than the data the filesystem should be:"
    while true; do
        choice=$(d_menu "Target size" "$mtext" 8 \
            10 "data + 10%   ($(human $(( floor*110/100 ))))" \
            20 "data + 20%   ($(human $(( floor*120/100 ))))" \
            30 "data + 30%   ($(human $(( floor*130/100 ))))" \
            40 "data + 40%   ($(human $(( floor*140/100 ))))" \
            50 "data + 50%   ($(human $(( floor*150/100 ))))" \
            manual "enter a size by hand (e.g. 12G)") || return 1
        if [[ "$choice" == manual ]]; then
            local v bytes
            v=$(d_input "Manual size" "Enter target filesystem size (e.g. 12G, 8000M).\nMinimum is $(human "$floor")." "") || continue
            bytes=$(numfmt --from=iec "${v//B/}" 2>/dev/null) || { d_msg "Invalid" "Could not parse '$v'."; continue; }
            if (( bytes < floor )); then
                d_msg "Too small" "Requested $(human "$bytes") is below the data minimum $(human "$floor"). Choose a larger size."
                continue
            fi
            CHOSEN_FS_BYTES=$bytes; return 0
        else
            pct=$choice
            CHOSEN_FS_BYTES=$(( floor * (100 + pct) / 100 ))
            return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# 7. Execute the shrink
# ---------------------------------------------------------------------------
do_shrink() {
    local vmid=$1
    # 7.1 shrink filesystem (skipped when only reclaiming trailing free space)
    if [[ ${TRAILING_ONLY:-0} -eq 1 ]]; then
        : # nothing to resize; the device is simply cut down to the last partition's end
    elif [[ $GUEST_LVM -eq 1 ]]; then
        # Compact mode reclaims only the VG's free space and never touches a filesystem, so
        # the lvreduce is skipped entirely (this is what makes XFS guests shrinkable). Deep
        # mode reduces one ext LV first to free extents below the target.
        if [[ ${LVM_COMPACT:-0} -eq 0 ]]; then
            log "lvreduce --resizefs -L ${NEW_FS_BYTES}B $FS_TARGET_DEV"
            ( lvreduce "${LVM_CFG[@]}" --resizefs -f -L "${NEW_FS_BYTES}B" "$FS_TARGET_DEV" >>"$LOGFILE" 2>&1 ) &
            gauge_wait $! 15 45 "Shrinking filesystem (LVM)" || die "lvreduce failed. See $LOGFILE"
        fi
        # Smallest PV size that still holds every allocated extent:
        # first-extent offset + allocated extents * extent size, plus one extent of slack.
        # pe_start can be large on zvol backed PVs (32 MiB data alignment), so it is read,
        # never assumed.
        local extent pestart alloc
        extent=$(vgs "${LVM_CFG[@]}" --noheadings --units b --nosuffix -o vg_extent_size "$ACTIVE_VG" 2>>"$LOGFILE" | tr -d ' ')
        pestart=$(pvs "${LVM_CFG[@]}" --noheadings --units b --nosuffix -o pe_start "$GUEST_PV" 2>>"$LOGFILE" | tr -d ' ')
        alloc=$(pvs "${LVM_CFG[@]}" --noheadings -o pv_pe_alloc_count "$GUEST_PV" 2>>"$LOGFILE" | tr -d ' ')
        [[ "$extent" =~ ^[0-9]+$ && "$pestart" =~ ^[0-9]+$ && "$alloc" =~ ^[0-9]+$ ]] \
            || die "Could not read LVM geometry (extent=$extent pe_start=$pestart alloc=$alloc)."
        local target_ext=$(( alloc + 1 ))
        PV_TARGET_BYTES=$(( pestart + target_ext * extent ))
        log "lvm geometry extent=$extent pe_start=$pestart alloc=$alloc target_ext=$target_ext pv_target=$PV_TARGET_BYTES"
        # pvresize only shrinks a PV if its physically-last extents are free. After reducing
        # one LV the freed extents can sit anywhere, so any extent still allocated at or
        # beyond the target offset is first moved down into that free space. Multi-LV VGs
        # (e.g. the Rocky/RHEL root+home+swap+tmp layout) need this, or pvresize aborts with
        # "cannot resize ... as later ones are allocated".
        progress 46 "Compacting physical extents"
        local pmout
        if ! pmout=$(pvmove -y --alloc anywhere "${LVM_CFG[@]}" "${GUEST_PV}:${target_ext}-" 2>&1); then
            echo "$pmout" >>"$LOGFILE"
            grep -qiE 'No data to move|no extents in range|does not exist' <<<"$pmout" \
                || die "pvmove (compacting extents before shrink) failed. See $LOGFILE"
        fi
        progress 48 "Resizing physical volume"
        pvresize -y "${LVM_CFG[@]}" --setphysicalvolumesize "${PV_TARGET_BYTES}B" "$GUEST_PV" >>"$LOGFILE" 2>&1 \
            || die "pvresize failed. See $LOGFILE"
        vgchange "${LVM_CFG[@]}" -an "$ACTIVE_VG" >>"$LOGFILE" 2>&1 || true; ACTIVE_VG=""
        # Recompute partition and device geometry from the real PV size.
        local align2=$(( MIB / SECTOR_SIZE ))
        if [[ ${NO_GPT:-0} -eq 1 ]]; then
            local d; d=$(roundup "$PV_TARGET_BYTES" "$MIB")
            [[ "$BACKEND" == zvol ]] && d=$(roundup "$d" "$VOLBLK")
            NEW_DEV_BYTES=$d
        else
            local psec=$(( (PV_TARGET_BYTES + SECTOR_SIZE - 1) / SECTOR_SIZE ))
            NEW_LAST_END=$(( LAST_START + psec - 1 ))
            NEW_LAST_END=$(( ( (NEW_LAST_END + align2) / align2 ) * align2 - 1 ))
            place_trailing
        fi
        log "lvm recomputed part_end=${NEW_LAST_END:-na} dev=$NEW_DEV_BYTES"
    elif [[ "$LAST_FS" == ntfs ]]; then
        log "ntfsresize --size ${NEW_FS_BYTES} $FS_TARGET_DEV"
        ( printf 'y\n' | ntfsresize --force --size "${NEW_FS_BYTES}" "$FS_TARGET_DEV" >>"$LOGFILE" 2>&1 ) &
        gauge_wait $! 15 50 "Shrinking NTFS filesystem" || die "ntfsresize failed. See $LOGFILE"
    else
        log "resize2fs $FS_TARGET_DEV ${NEW_FS_BYTES} bytes"
        ( resize2fs "$FS_TARGET_DEV" "$(( NEW_FS_BYTES / 4096 ))" >>"$LOGFILE" 2>&1 ) &
        gauge_wait $! 15 50 "Shrinking filesystem" || die "resize2fs failed. See $LOGFILE"
    fi

    # 7.2 / 7.3 partition work only applies to partitioned (GPT) disks, and is skipped when
    # only reclaiming trailing free space (no partition is resized or moved then)
    if [[ ${NO_GPT:-0} -eq 0 && ${TRAILING_ONLY:-0} -eq 0 ]]; then
        # capture trailing swap UUIDs now, while the original partition mapping is intact
        declare -A SWAP_UUIDS=()
        local te tn tf
        for te in "${TRAIL_NEW[@]:-}"; do
            [[ -n "$te" ]] || continue
            IFS=: read -r tn _ _ _ _ tf <<<"$te"
            [[ "$tf" == swap ]] && SWAP_UUIDS[$tn]=$(blkid -o value -s UUID "$(partdev "$tn")" 2>/dev/null || echo "")
        done

        progress 55 "Shrinking partition $LAST_N"
        # shrink the chosen partition: start unchanged, new smaller end, identity kept
        sgdisk -d "$LAST_N" "$BASE" >>"$LOGFILE" 2>&1
        sgdisk -n "${LAST_N}:${LAST_START}:${NEW_LAST_END}" \
               -t "${LAST_N}:${LAST_TYPE}" -u "${LAST_N}:${LAST_GUID}" \
               ${LAST_NAME:+-c "${LAST_N}:${LAST_NAME}"} "$BASE" >>"$LOGFILE" 2>&1 \
            || die "Recreating partition $LAST_N failed. The original layout is in $LOGFILE."
        apply_attrs "$LAST_N" "${LAST_ATTRS:-}"

        # move every trailing partition down into the freed space, keeping order and
        # identity. Data partitions are relocated block-for-block; swap is recreated.
        local e num os oe ns ne fs info tguid tuniq tname tattrs cnt suuid pct=57
        for e in "${TRAIL_NEW[@]:-}"; do
            [[ -n "$e" ]] || continue
            IFS=: read -r num os oe ns ne fs <<<"$e"
            info=$(sgdisk -i "$num" "$BASE")
            tguid=$(sed -n 's/Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p' <<<"$info")
            tuniq=$(sed -n 's/Partition unique GUID: \([0-9A-Fa-f-]*\).*/\1/p' <<<"$info")
            tname=$(sed -n "s/Partition name: '\(.*\)'/\1/p" <<<"$info")
            tattrs=$(sed -n 's/.*Attribute flags: *\([0-9A-Fa-f]*\).*/\1/p' <<<"$info")
            if [[ "$fs" == swap ]]; then
                suuid=${SWAP_UUIDS[$num]:-}
                sgdisk -d "$num" "$BASE" >>"$LOGFILE" 2>&1
                sgdisk -n "${num}:${ns}:${ne}" -t "${num}:${tguid}" -u "${num}:${tuniq}" \
                       ${tname:+-c "${num}:${tname}"} "$BASE" >>"$LOGFILE" 2>&1 || die "Recreating swap $num failed."
                apply_attrs "$num" "$tattrs"
                partx -u "$BASE" >>"$LOGFILE" 2>&1 || true; udevadm settle 2>/dev/null || true; sleep 1
                progress "$pct" "Recreating swap (part $num)"
                mkswap ${suuid:+-U "$suuid"} "$(partdev "$num")" >>"$LOGFILE" 2>&1 || die "mkswap failed on part $num."
            else
                # relocate raw blocks; moving DOWN with an ascending copy is overlap-safe
                cnt=$(( oe - os + 1 ))
                log "move part$num data: sector $os -> $ns ($cnt sectors)"
                ( dd if="$BASE" of="$BASE" bs=4M conv=notrunc \
                     iflag=skip_bytes,count_bytes oflag=seek_bytes \
                     skip=$(( os * SECTOR_SIZE )) seek=$(( ns * SECTOR_SIZE )) count=$(( cnt * SECTOR_SIZE )) \
                     >>"$LOGFILE" 2>&1 ) &
                gauge_wait $! "$pct" $((pct+8)) "Moving partition $num" || die "Moving partition $num failed."
                sgdisk -d "$num" "$BASE" >>"$LOGFILE" 2>&1
                sgdisk -n "${num}:${ns}:${ne}" -t "${num}:${tguid}" -u "${num}:${tuniq}" \
                       ${tname:+-c "${num}:${tname}"} "$BASE" >>"$LOGFILE" 2>&1 || die "Recreating moved partition $num failed."
                apply_attrs "$num" "$tattrs"
            fi
            pct=$((pct+8)); (( pct > 66 )) && pct=66
        done
        partx -u "$BASE" >>"$LOGFILE" 2>&1 || true; udevadm settle 2>/dev/null || true; sleep 1
    fi

    # 7.4 detach before touching the block device geometry
    progress 65 "Detaching disk"
    detach_disk

    # 7.5 shrink the backing block device
    case "$BACKEND" in
        zvol)
            log "zfs set volsize=${NEW_DEV_BYTES} $ZVOL"
            ( zfs set volsize="${NEW_DEV_BYTES}" "$ZVOL" >>"$LOGFILE" 2>&1 ) &
            gauge_wait $! 70 90 "Shrinking zvol" || die "zfs set volsize failed."
            ;;
        qcow2|rawlv)
            log "qemu-img resize --shrink $DISK_PATH ${NEW_DEV_BYTES}"
            ( qemu-img resize --shrink "$DISK_PATH" "${NEW_DEV_BYTES}" >>"$LOGFILE" 2>&1 ) &
            gauge_wait $! 70 90 "Shrinking $BACKEND image" || die "qemu-img resize failed."
            ;;
        rawfile)
            log "qemu-img resize --shrink -f raw $DISK_PATH ${NEW_DEV_BYTES}"
            ( qemu-img resize --shrink -f raw "$DISK_PATH" "${NEW_DEV_BYTES}" >>"$LOGFILE" 2>&1 ) &
            gauge_wait $! 70 90 "Shrinking image file" || die "qemu-img resize failed."
            ;;
        ctlvm)
            # lvreduce rounds to whole extents; round the target UP to the extent size so the
            # logical volume can never end up smaller than the filesystem just resized into it.
            local ctvg ctext ctdev
            ctvg=$(lvs --noheadings -o vg_name "$DISK_PATH" 2>>"$LOGFILE" | tr -d ' ')
            ctext=$(vgs --noheadings --units b --nosuffix -o vg_extent_size "$ctvg" 2>>"$LOGFILE" | tr -d ' ')
            [[ "$ctext" =~ ^[0-9]+$ ]] || ctext=$(( 4 * MIB ))
            ctdev=$(( (NEW_DEV_BYTES + ctext - 1) / ctext * ctext ))
            log "lvreduce -f -L ${ctdev}b $DISK_PATH (vg=$ctvg extent=$ctext)"
            ( lvreduce -f -L "${ctdev}b" "$DISK_PATH" >>"$LOGFILE" 2>&1 ) &
            gauge_wait $! 70 90 "Shrinking logical volume" || die "lvreduce failed."
            NEW_DEV_BYTES=$ctdev
            ;;
    esac

    # 7.6 move the GPT backup header to the new end and verify (GPT disks only)
    if [[ ${NO_GPT:-0} -eq 0 ]]; then
        local vbase
        case "$BACKEND" in
            zvol|rawlv) vbase=$DISK_PATH ;;
            qcow2)
                modprobe nbd max_part=16 2>>"$LOGFILE" || true
                local n
                for n in $(seq 0 15); do
                    [[ -e "/sys/block/nbd$n/pid" ]] && continue
                    if qemu-nbd -c "/dev/nbd$n" "$DISK_PATH" >>"$LOGFILE" 2>&1; then NBD_DEV="/dev/nbd$n"; break; fi
                done
                vbase=$NBD_DEV
                ;;
        esac
        udevadm settle 2>/dev/null || true; sleep 1
        progress 92 "Fixing GPT backup header"
        sgdisk -e "$vbase" >>"$LOGFILE" 2>&1 || die "sgdisk -e (move GPT backup) failed."
        progress 95 "Verifying partition table"
        if ! sgdisk -v "$vbase" >>"$LOGFILE" 2>&1; then
            die "GPT verification failed after shrink. Do not start the VM; inspect $LOGFILE."
        fi
        [[ -n "$NBD_DEV" ]] && { qemu-nbd -d "$NBD_DEV" >>"$LOGFILE" 2>&1 || true; NBD_DEV=""; }
    fi

    # 7.7 sync the guest config
    progress 97 "Updating $(guest_noun) config"
    if [[ $GUEST_TYPE == ct ]]; then
        ct_set_size "$vmid" "$DISK_KEY" "$NEW_DEV_BYTES"
    else
        qm rescan --vmid "$vmid" >>"$LOGFILE" 2>&1 || true
    fi
    log "shrink complete $GUEST_TYPE=$vmid new_dev=$NEW_DEV_BYTES"
}

# Write the new size (MiB) into a container volume's line in /etc/pve/lxc/<id>.conf.
# pct resize only grows, so the config is edited directly after an offline shrink.
ct_set_size() {
    local id=$1 key=$2 bytes=$3
    local conf="/etc/pve/lxc/${id}.conf"
    local mib=$(( bytes / MIB ))
    log "ct_set_size $conf $key -> ${mib}M"
    sed -i -E "/^${key}: /{ s/(,size=)[0-9A-Za-z.]+/\\1${mib}M/ }" "$conf" 2>>"$LOGFILE" \
        || log "warning: could not update size for $key in $conf"
}

# Shrink a container whose volume is a ZFS subvol by lowering the dataset refquota to the
# referenced data plus a chosen headroom. No filesystem or block device is touched, which
# makes it safe, filesystem agnostic and reversible. Self-contained (own confirm/execute).
ct_subvol_shrink() {
    local id=$1 referenced curq curb new
    referenced=$(zfs get -Hp -o value referenced "$DATASET" 2>>"$LOGFILE")
    [[ "$referenced" =~ ^[0-9]+$ ]] || die "Could not read the referenced size of $DATASET."
    MIN_FS_BYTES=$referenced
    curq=$(zfs get -H -o value refquota "$DATASET" 2>>"$LOGFILE")          # human, or "none"
    ask_target || { clear; exit 0; }                                      # CHOSEN_FS_BYTES >= referenced
    new=$(roundup "$CHOSEN_FS_BYTES" "$MIB")
    curb=$(zfs get -Hp -o value refquota "$DATASET" 2>/dev/null)
    [[ "$curb" =~ ^[0-9]+$ ]] || curb=0                                    # none -> unlimited
    if (( curb > 0 && new >= curb )); then
        d_msg "Nothing to do" "The new refquota ($(human "$new")) is not smaller than the current one ($(human "$curb")). No changes made."
        clear; exit 0
    fi
    local summary
    summary=$(cat <<EOF

CT:              $id
Volume:          $DISK_KEY  ($DISK_VOL)
Scheme:          Linux container on ZFS (subvol)
Dataset:         $DATASET
Mode:            lower the dataset refquota (no filesystem is touched)

Data referenced:  $(human "$referenced")
Current refquota: $([[ "$curq" == none ]] && echo "unlimited" || echo "$curq")
New refquota:     $(human "$new")

Steps: zfs set refquota -> update CT config
EOF
)
    if [[ $DRY_RUN -eq 1 ]]; then
        d_msg "Dry run (no changes made)" "$summary" 20 78
        clear; printf 'Dry run complete. Plan written to %s\n' "$LOGFILE"; exit 0
    fi
    if ! d_yesno "Confirm shrink" "$summary\n\nProceed?" 22 78; then clear; exit 0; fi
    start_gauge; progress 40 "Setting refquota"
    zfs set refquota="${new}" "$DATASET" >>"$LOGFILE" 2>&1 || die "zfs set refquota failed. See $LOGFILE."
    progress 97 "Updating CT config"
    ct_set_size "$id" "$DISK_KEY" "$new"
    stop_gauge
    log "subvol shrink ct=$id dataset=$DATASET refquota=$new"
    local msg="Shrink complete.\n\nNew refquota: $(human "$new")\nDataset: $DATASET\nLog: $LOGFILE"
    if d_yesno "Done - start CT?" "$msg\n\nStart CT $id now?"; then
        guest_start "$id" >>"$LOGFILE" 2>&1 || die "Starting CT $id failed. Check the console."
        msg="$msg\n\nCT started."
    fi
    clear
    printf '%b\n' "$msg"
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
main() {
    for a in "$@"; do
        case "$a" in
            --dry-run) DRY_RUN=1 ;;
            --debug)   DEBUG=1 ;;
            -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        esac
    done
    if [[ $DEBUG -eq 1 ]]; then mkdir -p "$LOGDIR"; exec 2>>"$LOGFILE"; set -x; fi

    preflight_env

    local vmid; vmid=$(select_guest) || { clear; exit 0; }
    if pct config "$vmid" >/dev/null 2>&1; then GUEST_TYPE=ct; else GUEST_TYPE=vm; fi
    local noun; noun=$(guest_noun)
    local diskkey; diskkey=$(select_volume "$vmid") || { clear; exit 0; }
    if [[ $GUEST_TYPE == ct ]]; then discover_ct "$vmid" "$diskkey"; else discover_disk "$vmid" "$diskkey"; fi

    # preflight: state, snapshots, protection, backup hint
    local status; status=$(guest_status "$vmid")
    if [[ "$status" != stopped ]]; then
        if d_yesno "$noun is running" "$noun $vmid is $status.\n\nThe volume must be offline to shrink it safely. Stop it now?"; then
            guest_stop "$vmid" >>"$LOGFILE" 2>&1 || die "Stopping $noun $vmid failed."
            for _ in $(seq 1 30); do [[ "$(guest_status "$vmid")" == stopped ]] && break; sleep 1; done
        else
            clear; exit 0
        fi
    fi
    local snapnames cnt
    snapnames=$(list_snapshots "$vmid")
    if [[ -n "$snapnames" ]]; then
        cnt=$(grep -c . <<<"$snapnames")
        if d_yesno "Snapshots present" "$noun $vmid has $cnt snapshot(s):\n\n$snapnames\n\nSnapshots block a shrink and cannot be kept. If you continue, ALL of these snapshots will be DELETED PERMANENTLY (this cannot be undone).\n\nDelete all snapshots and continue?" 20 74; then
            # delete leaf-first (reverse of the listed root->child order)
            local s
            while read -r s; do
                [[ -n "$s" ]] || continue
                guest_delsnap "$vmid" "$s" >>"$LOGFILE" 2>&1 || die "Failed to delete snapshot '$s'. Aborting; no shrink performed."
            done < <(tac <<<"$snapnames")
            [[ -z "$(list_snapshots "$vmid")" ]] || die "Snapshots still present after deletion. Aborting."
            log "deleted $cnt snapshots on $GUEST_TYPE=$vmid"
        else
            clear; exit 0
        fi
    fi
    if grep -q '^protection: 1' <(guest_config "$vmid"); then
        if d_yesno "Protection enabled" "$noun $vmid has protection=1.\n\nDisable it for the shrink and re-enable it automatically at the end (also on cancel or error)?"; then
            guest_setprot "$vmid" 0 >>"$LOGFILE" 2>&1 || die "Could not disable protection."
            PROTECTION_VMID=$vmid
        else
            d_msg "Protection kept" "Protection stays enabled. If a step is blocked by it, re-run and allow disabling."
        fi
    fi

    if ! d_yesno "Backup reminder" "This tool does NOT create any backup.\n\nMake sure a current backup of $noun $vmid exists before continuing.\n\nContinue?"; then
        clear; exit 0
    fi

    # ZFS subvol containers shrink by lowering the dataset refquota; no block or filesystem
    # work, so they take a dedicated path.
    if [[ "$BACKEND" == zfssubvol ]]; then
        ct_subvol_shrink "$vmid"
        return
    fi

    # attach + analyze + choose partition
    attach_disk
    analyze
    select_partition
    compute_trailing_free

    # Choose the shrink mode. Guest LVM gets its own chooser (trailing / compact / shrinkfs);
    # everything else picks between trailing-only and shrinking the partition's filesystem.
    # Prefer the safe path: reclaim free space without touching a filesystem whenever possible.
    if [[ $GUEST_LVM -eq 1 ]]; then
        lvm_prepare
        ask_lvm_mode || { detach_disk; clear; exit 0; }
    else
        SHRINK_MODE=partition
        if (( TRAIL_FREE_BYTES >= 1024*MIB )); then
            ask_mode || { detach_disk; clear; exit 0; }
        fi
    fi

    case "$SHRINK_MODE" in
        trailing) plan_trailing_only ;;
        compact)  plan_lvm_compact ;;
        shrinkfs)
            compute_min_lv
            ask_target || { detach_disk; clear; exit 0; }
            NEW_FS_BYTES=$(roundup "$CHOSEN_FS_BYTES" "$MIB")
            plan_lvm "$(( PV_USED_BYTES - (LV_TARGET_CUR - NEW_FS_BYTES) ))"
            ;;
        *)  # non-LVM partition filesystem shrink
            compute_min
            ask_target || { detach_disk; clear; exit 0; }
            plan_sizes "$CHOSEN_FS_BYTES"
            ;;
    esac

    # safety: never grow, and require a meaningful reduction
    local cur_bytes=$(( SECTORS * SECTOR_SIZE ))
    if (( NEW_DEV_BYTES >= cur_bytes )); then
        detach_disk
        d_msg "Nothing to do" "The computed new size ($(human "$NEW_DEV_BYTES")) is not smaller than the current size ($(human "$cur_bytes")).\n\nThe disk is already as small as the data allows. No changes made."
        clear; exit 0
    fi

    # summary / confirmation
    local scheme layout
    scheme=$(classify_layout)
    if [[ ${NO_GPT:-0} -eq 1 ]]; then
        layout="whole-disk $LAST_FS (no partition table)"
    elif [[ $GUEST_LVM -eq 1 ]]; then
        layout="LVM on GPT (VG $ACTIVE_VG: ${LVM_FS_LIST% })"
    else
        layout="$LAST_FS, partition $LAST_N"
    fi
    (( ${#TRAIL_NEW[@]} )) && layout="$layout, ${#TRAIL_NEW[@]} partition(s) after it moved down (order kept)"
    local summary
    if [[ ${TRAILING_ONLY:-0} -eq 1 ]]; then
        summary=$(cat <<EOF

${noun}:              $vmid
Volume:          $DISK_KEY  ($DISK_VOL)
Scheme:          $scheme
Backend:         $BACKEND
Layout:          $layout
Mode:            reclaim trailing free space only (no filesystem/partition/LVM change)

Free after last partition: $(human "$TRAIL_FREE_BYTES")
New device size: $(human "$NEW_DEV_BYTES")   (currently $(human $(( SECTORS * SECTOR_SIZE ))))

Steps: shrink $BACKEND -> fix GPT backup -> qm rescan
EOF
)
    elif [[ ${LVM_COMPACT:-0} -eq 1 ]]; then
        summary=$(cat <<EOF

${noun}:              $vmid
Volume:          $DISK_KEY  ($DISK_VOL)
Scheme:          $scheme
Backend:         $BACKEND
Layout:          $layout
Mode:            compact the volume group (pvmove + pvresize; no filesystem is touched)

Used by the VG:  $(human "$PV_USED_BYTES")
New device size: $(human "$NEW_DEV_BYTES")   (currently $(human $(( SECTORS * SECTOR_SIZE ))))

Steps: compact PV -> shrink partition $LAST_N -> shrink $BACKEND -> fix GPT backup -> qm rescan
EOF
)
    else
        local steps
        if [[ ${NO_GPT:-0} -eq 1 ]]; then
            steps="resize filesystem -> shrink $BACKEND -> update $noun config"
        else
            steps="resize filesystem -> shrink partition -> move trailing partitions -> shrink $BACKEND -> fix GPT backup -> qm rescan"
        fi
        summary=$(cat <<EOF

${noun}:              $vmid
Volume:          $DISK_KEY  ($DISK_VOL)
Scheme:          $scheme
Backend:         $BACKEND
Layout:          $layout

Data in use:     $(human "$MIN_FS_BYTES")
New filesystem:  $(human "$NEW_FS_BYTES")
New device size: $(human "$NEW_DEV_BYTES")   (currently $(human $(( SECTORS * SECTOR_SIZE ))))

Steps: $steps
EOF
)
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        detach_disk
        d_msg "Dry run (no changes made)" "$summary" 22 78
        clear; printf 'Dry run complete. Plan written to %s\n' "$LOGFILE"; exit 0
    fi

    if ! d_yesno "Confirm shrink" "$summary\n\nProceed? This modifies the disk." 24 78; then
        detach_disk; clear; exit 0
    fi

    # No backup files are created. The original partition layout is written to the log
    # (readable) before any change, so it can be recreated by hand if it is ever needed.
    { echo "--- original partition table of $DISK_VOL ---"; sgdisk -p "$BASE" 2>/dev/null; } >>"$LOGFILE" 2>&1 || true

    start_gauge
    do_shrink "$vmid"
    stop_gauge

    local msg="Shrink complete.\n\nNew size: $(human "$NEW_DEV_BYTES")\nLog: $LOGFILE"
    if d_yesno "Done - start $noun?" "$msg\n\nStart $noun $vmid now?"; then
        guest_start "$vmid" >>"$LOGFILE" 2>&1 || die "Starting $noun $vmid failed. Check the console."
        msg="$msg\n\n$noun started. Watch the console for a clean boot."
    fi
    clear
    printf '%b\n' "$msg"
}

# Only run the interactive flow when executed directly; sourcing exposes the
# functions for testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
