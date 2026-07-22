# shellcheck shell=dash
# shellcheck disable=SC2034  # consumed by tests/qemu/run.sh after sourcing
#
# Simulate a mid-apply crash without SIGKILL'ing qemu (that corrupts writeback
# qcow2 under virt and requires a multi-GB rootless e2fsck rewrite).
# Guest wrapper: start apply-base, kill it after a short window, sync, poweroff.
# Recovery boot then completes apply.

QEMU_RUNTIME=power-cut

scenario_fault_pre() {
    _spf_img="$1"
    qemu_rootfs_mount "$_spf_img"
    install -d "$QEMU_ROOTFS_MNT/usr/local/lib/rpi-preseed-probe"
    cat >"$QEMU_ROOTFS_MNT/usr/local/lib/rpi-preseed-probe/powercut-apply.sh" <<'EOF'
#!/bin/sh
# Mid-apply hard kill of the apply process (not the VM), then clean poweroff.
set -eu
/usr/bin/rpi-preseed apply-base &
_pid=$!
# Give apply time to mutate hostname/user state, then interrupt before stamp.
sleep 2
kill -9 "$_pid" 2>/dev/null || true
wait "$_pid" 2>/dev/null || true
sync
# Clean guest shutdown so the host does not need to e2fsck a trashed superblock.
systemctl poweroff
# Fallback if poweroff is slow.
sleep 5
echo o > /proc/sysrq-trigger 2>/dev/null || true
EOF
    chmod 755 "$QEMU_ROOTFS_MNT/usr/local/lib/rpi-preseed-probe/powercut-apply.sh"
    mkdir -p "$QEMU_ROOTFS_MNT/etc/systemd/system/rpi-preseed.service.d"
    cat >"$QEMU_ROOTFS_MNT/etc/systemd/system/rpi-preseed.service.d/powercut.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/lib/rpi-preseed-probe/powercut-apply.sh
EOF
    qemu_rootfs_umount
}
