#!/usr/bin/env bash
# lib/usb.sh — Ventoy USB detection and safe mounting
# Requires lib/common.sh to be sourced first.

# ── find_ventoy_disk ──────────────────────────────────────────────────────────
# Prints the block device path (e.g. /dev/sdb) of a Ventoy USB disk.
# Aborts if none or multiple found, or if matched device is the system disk.
find_ventoy_disk() {
    # Determine root disk (to never touch it)
    local root_dev root_disk
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null || df / | tail -1 | awk '{print $1}')
    root_disk=$(lsblk -ndo pkname "$root_dev" 2>/dev/null || basename "$root_dev" | sed 's/[0-9]*$//')

    local candidates=()
    while IFS= read -r disk; do
        local base; base=$(basename "$disk")

        # Safety: never touch the system disk
        [[ "$base" == "$root_disk" ]] && continue

        # Detect Ventoy by looking for VTOY* labels on any partition of this disk
        if lsblk -nlo LABEL "${disk}"* 2>/dev/null | grep -qiE '^VTOY|^VENTOY'; then
            candidates+=("$disk")
        fi
    done < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')

    if [[ "${#candidates[@]}" -eq 0 ]]; then
        die "No Ventoy USB disk detected. Please insert the Ventoy USB stick and retry."
    fi

    if [[ "${#candidates[@]}" -gt 1 ]]; then
        die "Multiple Ventoy disks found: ${candidates[*]}. Connect only one Ventoy stick."
    fi

    echo "${candidates[0]}"
}

# ── mount_ventoy_data ─────────────────────────────────────────────────────────
# Mounts the Ventoy data partition (partition 1) to the given mountpoint.
# If already mounted (e.g. auto-mounted by GNOME/udisks under /run/media/...),
# uses that existing mountpoint instead of remounting.
# Prints the mountpoint path.
mount_ventoy_data() {
    local disk="$1"
    local mnt="${2:-/mnt/ventoy}"

    local part="${disk}1"
    [[ -b "$part" ]] || die "Ventoy data partition $part not found on $disk."

    # Check if already mounted anywhere (covers /run/media/... auto-mounts)
    local existing_mnt
    existing_mnt=$(findmnt -n -o TARGET "$part" 2>/dev/null | head -1)
    if [[ -n "$existing_mnt" ]]; then
        log_info "Ventoy data partition already mounted at $existing_mnt"
        echo "$existing_mnt"
        return 0
    fi

    run mkdir -p "$mnt"
    run mount "$part" "$mnt"
    log_info "Mounted $part → $mnt"
    echo "$mnt"
}

# ── umount_ventoy_data ────────────────────────────────────────────────────────
# Only unmounts if we mounted it ourselves (i.e. not an auto-mount by udisks/GNOME).
# Auto-mounts live under /run/media/ and must not be unmounted by us.
umount_ventoy_data() {
    local mnt="${1:-/mnt/ventoy}"
    case "$mnt" in
        /run/media/*)
            log_info "Auto-mounted by system ($mnt) — skipping unmount."
            return 0
            ;;
    esac
    if mountpoint -q "$mnt" 2>/dev/null; then
        run sync
        run umount "$mnt"
        log_info "Unmounted $mnt"
    fi
}

# ── assert_disk_not_system ────────────────────────────────────────────────────
# Extra guard: refuse to operate on a disk that hosts any mounted filesystem.
assert_disk_not_system() {
    local disk="$1"
    while IFS= read -r mp; do
        [[ -z "$mp" ]] && continue
        case "$mp" in
            /|/boot|/boot/efi|/home|[[]SWAP[]])
                die "Safety check failed: $disk has mounted system partitions. Aborting."
                ;;
        esac
    done < <(lsblk -nlo MOUNTPOINT "${disk}"* 2>/dev/null)
}
