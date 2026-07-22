# shellcheck shell=dash
# Rootless disk access without libguestfs: qemu-storage-daemon (qcow2) + fuse2fs (ext4).

# State for the active disk map / rootfs mount.
QEMU_DISK_MAP=
QEMU_DISK_MAP_PID=
QEMU_DISK_MAP_FILE=
QEMU_ROOTFS_MNT=

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

# qemu_disk_map IMAGE — expose IMAGE as a raw-mappable file (identity for raw; FUSE for qcow2).
# Sets QEMU_DISK_MAP (path) and optional QEMU_DISK_MAP_PID / QEMU_DISK_MAP_FILE.
qemu_disk_map() {
    _qdm_img="$1"
    qemu_disk_unmap
    case "$_qdm_img" in
        *.qcow2)
            if ! qemu_have qemu-storage-daemon; then
                qemu_die "need qemu-storage-daemon to edit qcow2 images"
            fi
            QEMU_DISK_MAP_FILE=$(mktemp)
            : >"$QEMU_DISK_MAP_FILE"
            _qdm_pidfile=$(mktemp)
            # --daemonize: parent returns after export is up. stderr must not be a
            # pipe to this shell (the allow_other warning alone will deadlock FUSE).
            qemu-storage-daemon \
                --daemonize \
                --blockdev "driver=file,filename=$_qdm_img,node-name=file" \
                --blockdev "driver=qcow2,file=file,node-name=qcow" \
                --export "type=fuse,id=exp0,node-name=qcow,mountpoint=$QEMU_DISK_MAP_FILE,writable=on" \
                --pidfile "$_qdm_pidfile" >/dev/null 2>&1 \
                || qemu_die "qemu-storage-daemon failed to export $_qdm_img"
            QEMU_DISK_MAP_PID=$(cat "$_qdm_pidfile" 2>/dev/null || true)
            rm -f "$_qdm_pidfile"
            [ -n "$QEMU_DISK_MAP_PID" ] || qemu_die "qemu-storage-daemon wrote no pid for $_qdm_img"
            QEMU_DISK_MAP="$QEMU_DISK_MAP_FILE"
            ;;
        *)
            QEMU_DISK_MAP="$_qdm_img"
            QEMU_DISK_MAP_PID=
            QEMU_DISK_MAP_FILE=
            ;;
    esac
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
    qemu_disk_map "$_qrm_img"
    _qrm_start=$(qemu_part_start_sectors "$QEMU_DISK_MAP" 2)
    _qrm_off=$((_qrm_start * 512))
    QEMU_ROOTFS_MNT=$(mktemp -d)
    if fuse2fs -o "offset=$_qrm_off,fakeroot,rw" "$QEMU_DISK_MAP" "$QEMU_ROOTFS_MNT" 2>/dev/null; then
        :
    else
        rmdir "$QEMU_ROOTFS_MNT" 2>/dev/null || true
        QEMU_ROOTFS_MNT=
        qemu_disk_unmap
        qemu_die "fuse2fs failed to mount rootfs of $_qrm_img"
    fi
    # shellcheck disable=SC2064
    trap 'qemu_rootfs_umount' EXIT INT TERM
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

