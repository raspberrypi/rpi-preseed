# shellcheck shell=dash
# Pull qemu probe results from the guest image and provide assertion helpers.

QEMU_RESULTS_GUEST="/var/lib/rpi-preseed/qemu-results"

# qemu_fetch_results IMAGE DEST_DIR
qemu_fetch_results() {
    _qfr_img="$1"
    _qfr_dest="$2"
    rm -rf "$_qfr_dest"
    mkdir -p "$_qfr_dest"
    qemu_rootfs_mount "$_qfr_img"
    if [ -f "$QEMU_ROOTFS_MNT$QEMU_RESULTS_GUEST/done" ]; then
        cp -a "$QEMU_ROOTFS_MNT$QEMU_RESULTS_GUEST/." "$_qfr_dest/"
        qemu_rootfs_umount
        return 0
    fi
    qemu_rootfs_umount
    return 1
}

# --- Assertion helpers (used by scenario expect.sh) -------------------------

qemu_assert_file() {
    if [ -f "$2" ]; then
        ok "$1"
    else
        no "$1 (missing: $2)"
    fi
}

qemu_assert_eq() {
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        no "$1 (want [$3] got [$2])"
    fi
}

qemu_assert_contains() {
    if grep -qF -- "$3" "$2" 2>/dev/null; then
        ok "$1"
    else
        no "$1 (missing [$3] in $2)"
    fi
}

qemu_assert_ncontains() {
    if grep -qF -- "$3" "$2" 2>/dev/null; then
        no "$1 (unexpectedly found [$3] in $2)"
    else
        ok "$1"
    fi
}

# qemu_assert_boot_partition DESC IMAGE has|lacks STRING — whether STRING is in
# the raw bytes of the FAT boot partition, freed clusters included.
qemu_assert_boot_partition() {
    qemu_disk_map "$2"
    _qbp_start=$(qemu_part_start_sectors "$QEMU_DISK_MAP" 1)
    _qbp_size=$(qemu_part_size_sectors "$QEMU_DISK_MAP" 1)
    _qbp_found=0
    dd if="$QEMU_DISK_MAP" bs=512 skip="$_qbp_start" count="$_qbp_size" status=none 2>/dev/null \
        | grep -qaF -- "$4" && _qbp_found=1
    qemu_disk_unmap
    case "$3:$_qbp_found" in
        has:1|lacks:0) ok "$1" ;;
        has:0) no "$1 (missing [$4] from the boot partition)" ;;
        *)     no "$1 (found [$4] on the boot partition)" ;;
    esac
}

qemu_assert_stamp() {
    _as_name="$1"
    _as_dir="$2"
    _as_want="$3"
    _as_path="$_as_dir/stamps/$_as_name"
    if [ "$_as_want" = present ]; then
        qemu_assert_file "stamp $_as_name present" "$_as_path"
    else
        if [ -f "$_as_path" ]; then
            no "stamp $_as_name absent (found $_as_path)"
        else
            ok "stamp $_as_name absent"
        fi
    fi
}
