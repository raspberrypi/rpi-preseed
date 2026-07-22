# shellcheck shell=dash
# Declarative fault injection for qemu scenarios (fuse2fs / mtools).

# qemu_fault_helper_fail IMAGE HELPER_PATH
qemu_fault_helper_fail() {
    _qfh_img="$1"
    _qfh_path="$2"
    qemu_rootfs_mount "$_qfh_img"
    mkdir -p "$QEMU_ROOTFS_MNT$(dirname -- "$_qfh_path")"
    cat >"$QEMU_ROOTFS_MNT$_qfh_path" <<'EOF'
#!/bin/sh
echo "rpi-preseed fault-inject: helper forced failure" >&2
exit 1
EOF
    chmod 755 "$QEMU_ROOTFS_MNT$_qfh_path"
    qemu_rootfs_umount
}

# qemu_fault_stamp IMAGE STAMP_NAME FINGERPRINT
qemu_fault_stamp() {
    _qfs_img="$1"
    _qfs_name="$2"
    _qfs_fp="$3"
    qemu_rootfs_mount "$_qfs_img"
    mkdir -p "$QEMU_ROOTFS_MNT/var/lib/rpi-preseed"
    printf 'timestamp=1970-01-01T00:00:00Z\nversion=0\nfingerprint=%s\n' "$_qfs_fp" \
        >"$QEMU_ROOTFS_MNT/var/lib/rpi-preseed/$_qfs_name"
    qemu_rootfs_umount
}

# qemu_fault_config_readonly IMAGE
# FAT +r does not make [ -w ] fail for root; remount /boot/firmware ro instead.
qemu_fault_config_readonly() {
    _qfc_img="$1"
    qemu_disk_map "$_qfc_img"
    _qfc_start=$(qemu_part_start_sectors "$QEMU_DISK_MAP" 1)
    if qemu_have mattrib; then
        mattrib +r -i "${QEMU_DISK_MAP}@@${_qfc_start}s" ::/rpi-preseed.toml 2>/dev/null || true
    fi
    qemu_disk_unmap
    qemu_rootfs_mount "$_qfc_img"
    mkdir -p "$QEMU_ROOTFS_MNT/etc/systemd/system/rpi-preseed.service.d"
    cat >"$QEMU_ROOTFS_MNT/etc/systemd/system/rpi-preseed.service.d/readonly-boot.conf" <<'EOF'
[Service]
# Force the redaction check ([ -w config ]) to take the read-only path.
ExecStartPre=/bin/mount -o remount,ro /boot/firmware
EOF
    qemu_rootfs_umount
}

# qemu_fault_clear_stamps IMAGE
qemu_fault_clear_stamps() {
    _qfc_img="$1"
    qemu_rootfs_mount "$_qfc_img"
    rm -f "$QEMU_ROOTFS_MNT/var/lib/rpi-preseed/applied" \
          "$QEMU_ROOTFS_MNT/var/lib/rpi-preseed/apply-failed" \
          "$QEMU_ROOTFS_MNT/var/lib/rpi-preseed/early-runcmd-done" \
          "$QEMU_ROOTFS_MNT/var/lib/rpi-preseed/runcmd-done"
    qemu_rootfs_umount
}
