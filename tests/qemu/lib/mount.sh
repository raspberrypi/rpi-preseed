# shellcheck shell=dash
# Rootless disk access without libguestfs: qemu-storage-daemon (qcow2) + fuse2fs (ext4).

# State for the active disk map / rootfs mount.
QEMU_DISK_MAP=
QEMU_DISK_MAP_PID=
QEMU_DISK_MAP_FILE=
QEMU_ROOTFS_MNT=
# Temp staging dir tracked so the global teardown can reclaim it on any exit.
QEMU_STAGE_DIR=

# qemu_teardown — best-effort teardown of everything the harness may leave behind:
# a running guest, the serial watcher, an ext4 FUSE mount, the qcow2 storage-daemon
# export, and the install staging dir. Idempotent and safe to call with nothing
# active, so it works as both a global EXIT/INT/TERM trap and a qemu_die hook.
qemu_teardown() {
    if command -v qemu_stop_watch >/dev/null 2>&1; then
        qemu_stop_watch 2>/dev/null || true
    fi
    if [ -n "${QEMU_PID:-}" ]; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=
    fi
    # Covers both a live rootfs mount and a bare disk map (no mount).
    qemu_rootfs_umount 2>/dev/null || true
    if [ -n "${QEMU_STAGE_DIR:-}" ]; then
        rm -rf "$QEMU_STAGE_DIR" 2>/dev/null || true
        QEMU_STAGE_DIR=
    fi
}

# qemu_part_start_sectors MAP_PATH PARTNUM — start sector of MBR partition PARTNUM.
# Prefer a direct MBR parse: sfdisk can hang or scan too slowly on FUSE-exported qcow2.
qemu_part_start_sectors() {
    _qps_map="$1"
    _qps_n="$2"
    if [ "$_qps_n" -lt 1 ] || [ "$_qps_n" -gt 4 ]; then
        qemu_die "partition number out of range: $_qps_n"
    fi
    # MBR partition table: entry N at offset 446 + (N-1)*16; LBA start at +8 (u32 LE).
    _qps_off=$((446 + (_qps_n - 1) * 16 + 8))
    _qps_start=$(dd if="$_qps_map" bs=1 skip="$_qps_off" count=4 2>/dev/null | od -An -tu4 | tr -d ' \n')
    [ -n "$_qps_start" ] && [ "$_qps_start" -gt 0 ] 2>/dev/null || \
        qemu_die "could not parse partition $_qps_n start from MBR of $_qps_map"
    printf '%s' "$_qps_start"
}

# _qemu_sd_wait_ready PID FILE — wait until a storage-daemon FUSE export is live.
# The empty temp mountpoint reports a non-zero size once the export mounts over it.
_qemu_sd_wait_ready() {
    _sdw_pid="$1"
    _sdw_file="$2"
    _sdw_i=0
    while [ "$_sdw_i" -lt 100 ]; do
        [ "$(stat -c %s "$_sdw_file" 2>/dev/null || echo 0)" -gt 0 ] && return 0
        kill -0 "$_sdw_pid" 2>/dev/null || return 1
        sleep 0.1 2>/dev/null || sleep 1
        _sdw_i=$((_sdw_i + 1))
    done
    return 1
}

# qemu_disk_map IMAGE [OFFSET SIZE] — expose IMAGE as a raw-mappable file.
# Whole disk: identity for raw, FUSE export for qcow2. With OFFSET+SIZE (bytes),
# exposes only that sub-range as a zero-offset image (used to hand fuse2fs a bare
# partition, since fuse2fs before e2fsprogs 1.47 has no offset= option).
# Sets QEMU_DISK_MAP (path) and optional QEMU_DISK_MAP_PID / QEMU_DISK_MAP_FILE.
qemu_disk_map() {
    _qdm_img="$1"
    _qdm_off="${2:-}"
    _qdm_size="${3:-}"
    qemu_disk_unmap

    # Whole-disk raw image: use the file directly (dd/od/mtools read it fine;
    # only fuse2fs needs a partition sub-range via the storage daemon).
    if [ -z "$_qdm_off" ]; then
        case "$_qdm_img" in
            *.qcow2) ;;
            *)
                QEMU_DISK_MAP="$_qdm_img"
                QEMU_DISK_MAP_PID=
                QEMU_DISK_MAP_FILE=
                return 0
                ;;
        esac
    fi

    if ! qemu_have qemu-storage-daemon; then
        qemu_die "need qemu-storage-daemon to map $_qdm_img"
    fi

    QEMU_DISK_MAP_FILE=$(mktemp)
    : >"$QEMU_DISK_MAP_FILE"

    # Build the block chain: file [-> qcow2] [-> raw sub-range]; export the top node.
    set -- --blockdev "driver=file,filename=$_qdm_img,node-name=file"
    _qdm_node="file"
    case "$_qdm_img" in
        *.qcow2)
            set -- "$@" --blockdev "driver=qcow2,file=file,node-name=disk"
            _qdm_node="disk"
            ;;
    esac
    if [ -n "$_qdm_off" ]; then
        set -- "$@" --blockdev "driver=raw,file=$_qdm_node,offset=$_qdm_off,size=$_qdm_size,node-name=part"
        _qdm_node=part
    fi

    # Background rather than --daemonize (that option only landed in QEMU 7.1, but
    # Ubuntu 22.04 ships 6.2.0). `&` works on every version and yields the daemon
    # PID directly. stderr must go to /dev/null, never a pipe to this shell (a lone
    # FUSE allow_other warning would deadlock the export).
    qemu-storage-daemon "$@" \
        --export "type=fuse,id=exp0,node-name=$_qdm_node,mountpoint=$QEMU_DISK_MAP_FILE,writable=on" \
        >/dev/null 2>&1 &
    QEMU_DISK_MAP_PID=$!

    if ! _qemu_sd_wait_ready "$QEMU_DISK_MAP_PID" "$QEMU_DISK_MAP_FILE"; then
        qemu_disk_unmap
        qemu_die "qemu-storage-daemon failed to export $_qdm_img (FUSE export did not come up)"
    fi
    QEMU_DISK_MAP="$QEMU_DISK_MAP_FILE"
}

qemu_disk_unmap() {
    # Unmount FUSE first so the storage-daemon drops its qcow2 write lock.
    if [ -n "${QEMU_DISK_MAP_FILE:-}" ]; then
        if qemu_have fusermount3; then
            fusermount3 -u "$QEMU_DISK_MAP_FILE" 2>/dev/null || true
        fi
        if qemu_have fusermount; then
            fusermount -u "$QEMU_DISK_MAP_FILE" 2>/dev/null || true
        fi
    fi
    if [ -n "${QEMU_DISK_MAP_PID:-}" ]; then
        kill "$QEMU_DISK_MAP_PID" 2>/dev/null || true
        _qdu_i=0
        while kill -0 "$QEMU_DISK_MAP_PID" 2>/dev/null; do
            if [ "$_qdu_i" -ge 20 ]; then
                kill -9 "$QEMU_DISK_MAP_PID" 2>/dev/null || true
                break
            fi
            sleep 0.05 2>/dev/null || sleep 1
            _qdu_i=$((_qdu_i + 1))
        done
        wait "$QEMU_DISK_MAP_PID" 2>/dev/null || true
        QEMU_DISK_MAP_PID=
    fi
    if [ -n "${QEMU_DISK_MAP_FILE:-}" ]; then
        rm -f "$QEMU_DISK_MAP_FILE"
        QEMU_DISK_MAP_FILE=
    fi
    QEMU_DISK_MAP=
}

# qemu_rootfs_mount IMAGE — mount partition 2 (ext4) at a temp dir; sets QEMU_ROOTFS_MNT.
qemu_rootfs_mount() {
    _qrm_img="$1"
    if ! qemu_have fuse2fs; then
        qemu_die "need fuse2fs (apt install fuse2fs) for rootless ext4 mounts"
    fi
    # Read partition 2 geometry from the MBR (whole-disk map), then release it.
    qemu_disk_map "$_qrm_img"
    _qrm_start=$(qemu_part_start_sectors "$QEMU_DISK_MAP" 2)
    _qrm_size=$(qemu_part_size_sectors "$QEMU_DISK_MAP" 2) || _qrm_size=0
    qemu_disk_unmap
    [ "$_qrm_size" -gt 0 ] 2>/dev/null || \
        qemu_die "could not determine rootfs partition size of $_qrm_img"

    # Re-map ONLY partition 2 as a zero-offset image, so fuse2fs needs no offset=
    # option (absent before e2fsprogs 1.47; Ubuntu 22.04 ships 1.46).
    qemu_disk_map "$_qrm_img" "$((_qrm_start * 512))" "$((_qrm_size * 512))"
    QEMU_ROOTFS_MNT=$(mktemp -d)
    if fuse2fs -o "fakeroot,rw" "$QEMU_DISK_MAP" "$QEMU_ROOTFS_MNT" 2>/dev/null; then
        :
    else
        rmdir "$QEMU_ROOTFS_MNT" 2>/dev/null || true
        QEMU_ROOTFS_MNT=
        qemu_disk_unmap
        qemu_die "fuse2fs failed to mount rootfs of $_qrm_img"
    fi
    # Teardown is handled globally (run.sh trap + qemu_die hook), so no per-mount
    # trap is needed here — and none that provision.sh would have to clear.
}

qemu_rootfs_umount() {
    if [ -z "${QEMU_ROOTFS_MNT:-}" ]; then
        qemu_disk_unmap
        return 0
    fi
    if qemu_have fusermount3; then
        fusermount3 -u "$QEMU_ROOTFS_MNT" 2>/dev/null || true
    fi
    if qemu_have fusermount; then
        fusermount -u "$QEMU_ROOTFS_MNT" 2>/dev/null || true
    fi
    umount "$QEMU_ROOTFS_MNT" 2>/dev/null || true
    rmdir "$QEMU_ROOTFS_MNT" 2>/dev/null || true
    QEMU_ROOTFS_MNT=
    qemu_disk_unmap
}

# qemu_part_size_sectors MAP_PATH PARTNUM — sector count of MBR partition PARTNUM.
qemu_part_size_sectors() {
    _qpsz_map="$1"
    _qpsz_n="$2"
    if [ "$_qpsz_n" -lt 1 ] || [ "$_qpsz_n" -gt 4 ]; then
        return 1
    fi
    _qpsz_off=$((446 + (_qpsz_n - 1) * 16 + 12))
    _qpsz_size=$(dd if="$_qpsz_map" bs=1 skip="$_qpsz_off" count=4 2>/dev/null | od -An -tu4 | tr -d ' \n')
    [ -n "$_qpsz_size" ] && [ "$_qpsz_size" -gt 0 ] 2>/dev/null || return 1
    printf '%s' "$_qpsz_size"
}

# qemu_fsck_rootfs IMAGE — repair dirty ext4 on partition 2 without losetup.
# For qcow2: extract via qemu-storage-daemon FUSE, e2fsck a sparse copy under
# RPI_PRESEED_QEMU_WORK, write the repaired partition back through FUSE.
qemu_fsck_rootfs() {
    _qfr_img="$1"
    if ! qemu_have e2fsck || ! qemu_have dd; then
        return 1
    fi
    _qfr_dir="${RPI_PRESEED_QEMU_WORK:-$HOME/.cache/rpi-preseed-qemu}"
    ensure_dir "$_qfr_dir"

    qemu_disk_map "$_qfr_img" || return 1
    _qfr_start=$(qemu_part_start_sectors "$QEMU_DISK_MAP" 2) || {
        qemu_disk_unmap
        return 1
    }
    _qfr_size=$(qemu_part_size_sectors "$QEMU_DISK_MAP" 2) || {
        qemu_disk_unmap
        return 1
    }
    _qfr_part="$_qfr_dir/fsck-part-$$.img"
    _qfr_rc=1

    if dd if=/dev/zero of="$_qfr_part" bs=512 count=0 seek="$_qfr_size" status=none 2>/dev/null \
       && dd if="$QEMU_DISK_MAP" of="$_qfr_part" bs=512 skip="$_qfr_start" count="$_qfr_size" \
            conv=notrunc status=none 2>/dev/null; then
        if e2fsck -f -p "$_qfr_part" >/dev/null 2>&1 \
           || e2fsck -f -y "$_qfr_part" >/dev/null 2>&1 \
           || e2fsck -E journal_only -y "$_qfr_part" >/dev/null 2>&1; then
            if dd if="$_qfr_part" of="$QEMU_DISK_MAP" bs=512 seek="$_qfr_start" count="$_qfr_size" \
                  conv=notrunc status=none 2>/dev/null; then
                _qfr_rc=0
            fi
        fi
    fi
    rm -f "$_qfr_part"
    qemu_disk_unmap
    return "$_qfr_rc"
}

# qemu_cleanup_stale_mounts — best-effort cleanup of leaked harness FUSE exports.
qemu_cleanup_stale_mounts() {
    if ! qemu_have ps; then
        return 0
    fi
    ps -ef 2>/dev/null | awk '/qemu-storage-daemon/ && /rpi-preseed-qemu/ && !/awk/ {print $2}' | \
        while read -r _qcs_pid; do
            kill -9 "$_qcs_pid" 2>/dev/null || true
        done
    ps -ef 2>/dev/null | awk '/fuse2fs/ && /offset=/ && !/awk/ {print $2}' | \
        while read -r _qcs_pid; do
            kill -9 "$_qcs_pid" 2>/dev/null || true
        done
}

