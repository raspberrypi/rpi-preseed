# shellcheck shell=dash
# Rootless image provisioning via fuse2fs (no libguestfs appliance).

# shellcheck disable=SC2034  # set here, consumed by tests/qemu/run.sh
export QEMU_PROVISIONED_IMAGE=

# qemu_stage_install DEST — run make install into a staging tree.
qemu_stage_install() {
    _qsi_dest="$1"
    rm -rf "$_qsi_dest"
    make -C "$QEMU_REPO" install DESTDIR="$_qsi_dest" PREFIX=/usr >/dev/null
}

# _qemu_provision_stamp_key — fingerprint rpi-preseed + probe for cache invalidation.
_qemu_provision_stamp_key() {
    # Bump the leading token when the provision strategy changes (e.g. fuse2fs).
    {
        echo fuse2fs-v10-timesync-stamp
        sha256sum "$QEMU_REPO/src/rpi-preseed" \
            "$QEMU_REPO/tests/qemu/probe/collect.sh" \
            "$QEMU_REPO/tests/qemu/probe/rpi-preseed-probe.service" \
            2>/dev/null
        # Kernel modules tree fingerprint (guest needs host virt kernel modules for vfat).
        if [ -n "${QEMU_KERNEL:-}" ]; then
            _qpsk_ver=$(basename -- "$QEMU_KERNEL" | sed 's/^vmlinuz-//')
            printf 'modules:%s\n' "$_qpsk_ver"
            ls "/lib/modules/$_qpsk_ver/modules.dep" 2>/dev/null | sha256sum
        fi
    } | sha256sum | awk '{print $1}'
}

# _qemu_install_virt_modules ROOTFS_MNT — copy minimal host modules so guest can mount vfat.
# Full module trees do not fit on an ungrown Pi OS Lite rootfs.
_qemu_install_virt_modules() {
    _qiv_mnt="$1"
    [ -n "${QEMU_KERNEL:-}" ] || return 0
    _qiv_ver=$(basename -- "$QEMU_KERNEL" | sed 's/^vmlinuz-//')
    _qiv_src="/lib/modules/$_qiv_ver"
    if [ ! -d "$_qiv_src" ]; then
        qemu_warn "no $_qiv_src; /boot/firmware may fail to mount under -M virt"
        return 0
    fi
    qemu_info "installing minimal host modules $_qiv_ver into guest (fat/vfat/nls)..."
    _qiv_dst="$_qiv_mnt/lib/modules/$_qiv_ver"
    mkdir -p "$_qiv_dst/kernel/fs/fat" "$_qiv_dst/kernel/fs/nls"
    for _qiv_rel in \
        kernel/fs/fat/fat.ko.xz \
        kernel/fs/fat/vfat.ko.xz \
        kernel/fs/nls/nls_cp437.ko.xz \
        kernel/fs/nls/nls_ascii.ko.xz \
        modules.dep modules.dep.bin modules.alias modules.alias.bin \
        modules.symbols modules.symbols.bin modules.builtin modules.builtin.bin \
        modules.softdep modules.devname
    do
        if [ -e "$_qiv_src/$_qiv_rel" ]; then
            mkdir -p "$_qiv_dst/$(dirname -- "$_qiv_rel")"
            cp -a "$_qiv_src/$_qiv_rel" "$_qiv_dst/$_qiv_rel"
        fi
    done
}

# _qemu_patch_fstab_for_virt ROOTFS_MNT — make /boot/firmware mount resilient on virtio.
_qemu_patch_fstab_for_virt() {
    _qpf_mnt="$1"
    _qpf_fstab="$_qpf_mnt/etc/fstab"
    [ -f "$_qpf_fstab" ] || return 0
    # Prefer /dev/vdaN (stable under -M virt) and nofail so a transient mount flake
    # does not drop the guest into emergency mode.
    if grep -q 'boot/firmware' "$_qpf_fstab"; then
        sed -i \
            -e 's|^PARTUUID=[^ ]*[ ]*/boot/firmware[ ]*vfat[ ].*|/dev/vda1  /boot/firmware  vfat    defaults,nofail  0       2|' \
            -e 's|^PARTUUID=[^ ]*[ ]*/[ ]*ext4[ ].*|/dev/vda2  /               ext4    defaults,noatime  0       1|' \
            "$_qpf_fstab" 2>/dev/null || true
    fi
    # Ensure vfat is attempted early.
    mkdir -p "$_qpf_mnt/etc/modules-load.d"
    printf '%s\n' fat vfat nls_cp437 nls_ascii >"$_qpf_mnt/etc/modules-load.d/rpi-preseed-qemu-virt.conf"
}

# _qemu_mask_systemd_unit ROOTFS_MNT UNIT — mask a unit under /etc/systemd/system.
_qemu_mask_systemd_unit() {
    _qmu_mnt="$1"
    _qmu_unit="$2"
    mkdir -p "$_qmu_mnt/etc/systemd/system"
    ln -sfn /dev/null "$_qmu_mnt/etc/systemd/system/$_qmu_unit"
}

# _qemu_disable_virt_incompatible_services ROOTFS_MNT — Pi swap/zram/USB/EEPROM
# services assume Pi hardware and can wedge boot under -M virt (loop/zram/dbus storms).
_qemu_disable_virt_incompatible_services() {
    _qvi_mnt="$1"
    for _qvi_u in \
        rpi-resize-swap-file.service \
        'rpi-setup-loop@.service' \
        'rpi-remove-swap-file@.service' \
        rpi-usb-gadget-ics.service \
        rpi-eeprom-update.service \
        rpi-zram-writeback.service \
        rpi-zram-writeback.timer \
        'systemd-zram-setup@.service' \
        dev-zram0.swap \
        NetworkManager.service \
        wpa_supplicant.service \
        avahi-daemon.service \
        nftables.service \
        systemd-timesyncd.service
    do
        _qemu_mask_systemd_unit "$_qvi_mnt" "$_qvi_u"
    done
    # Satisfy late's After=network-online / time-sync without waiting on NTP under virt.
    mkdir -p "$_qvi_mnt/etc/systemd/system/network-online.target.wants" \
             "$_qvi_mnt/etc/systemd/system/time-sync.target.wants"
    cat >"$_qvi_mnt/etc/systemd/system/rpi-preseed-qemu-netonline.service" <<'EOF'
[Unit]
Description=rpi-preseed qemu: satisfy network-online under -M virt
Before=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=network-online.target
EOF
    # Late gate waits on /run/systemd/timesync/synchronized when timesyncd is masked.
    cat >"$_qvi_mnt/etc/systemd/system/rpi-preseed-qemu-timesync.service" <<'EOF'
[Unit]
Description=rpi-preseed qemu: mark NTP synchronized under -M virt
DefaultDependencies=no
After=local-fs.target
Before=time-sync.target rpi-preseed-runcmd-late.service
Wants=time-sync.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mkdir -p /run/systemd/timesync
ExecStart=/bin/touch /run/systemd/timesync/synchronized

[Install]
WantedBy=sysinit.target time-sync.target
EOF
    mkdir -p "$_qvi_mnt/etc/systemd/system/sysinit.target.wants" \
             "$_qvi_mnt/etc/systemd/system/time-sync.target.wants"
    ln -sfn /etc/systemd/system/rpi-preseed-qemu-netonline.service \
        "$_qvi_mnt/etc/systemd/system/network-online.target.wants/rpi-preseed-qemu-netonline.service"
    ln -sfn /etc/systemd/system/rpi-preseed-qemu-timesync.service \
        "$_qvi_mnt/etc/systemd/system/time-sync.target.wants/rpi-preseed-qemu-timesync.service"
    ln -sfn /etc/systemd/system/rpi-preseed-qemu-timesync.service \
        "$_qvi_mnt/etc/systemd/system/sysinit.target.wants/rpi-preseed-qemu-timesync.service"
    mkdir -p "$_qvi_mnt/etc/systemd"
    cat >"$_qvi_mnt/etc/systemd/zram-generator.conf" <<'EOF'
# Disabled for qemu -M virt (no zram module in Debian virt kernel initrd).
[general]
enabled = false
EOF
}

# _qemu_disable_firstboot_blockers ROOTFS_MNT — Pi OS userconfig/cloud-init dialogs
# block multi-user.target (interactive), which would stall the qemu probe forever.
_qemu_disable_firstboot_blockers() {
    _qdb_mnt="$1"
    for _qdb_u in userconfig.service \
                  regenerate_ssh_host_keys.service \
                  cloud-init.service \
                  cloud-init-local.service \
                  cloud-config.service \
                  cloud-final.service \
                  packagekit.service \
                  packagekit-offline-update.service
    do
        _qemu_mask_systemd_unit "$_qdb_mnt" "$_qdb_u"
    done
    # Ensure a usable local user exists so nothing else waits on first-boot wizards.
    if [ -f "$_qdb_mnt/etc/passwd" ] && ! grep -q '^pi:' "$_qdb_mnt/etc/passwd"; then
        printf 'pi:x:1000:1000:,,,:/home/pi:/bin/bash\n' >>"$_qdb_mnt/etc/passwd"
        printf 'pi:x:1000:\n' >>"$_qdb_mnt/etc/group"
        mkdir -p "$_qdb_mnt/home/pi"
    fi
}

# qemu_prepare_provisioned_image PREPARED_IMG CACHE_DIR
# One-time fuse2fs install into a qcow2 overlay (no multi-GB full copy).
qemu_prepare_provisioned_image() {
    _qppi_prepared="$1"
    _qppi_cache="$2"
    _qppi_out="$_qppi_cache/provisioned.qcow2"
    _qppi_stamp="$_qppi_cache/provisioned.stamp"
    _qppi_key=$(_qemu_provision_stamp_key)

    if [ -f "$_qppi_out" ] && [ -f "$_qppi_stamp" ] && \
       [ "$_qppi_key" = "$(cat "$_qppi_stamp" 2>/dev/null)" ]; then
        QEMU_PROVISIONED_IMAGE="$_qppi_out"
        qemu_info "using cached provisioned image $_qppi_out"
        return 0
    fi

    if ! qemu_have qemu-img; then
        qemu_die "need qemu-img to create provisioned.qcow2 overlay"
    fi

    qemu_info "installing rpi-preseed into base image (qcow2 overlay + fuse2fs)..."
    rm -f "$_qppi_out"
    qemu-img create -f qcow2 -o "backing_file=$_qppi_prepared,backing_fmt=raw" "$_qppi_out" >/dev/null

    _qppi_stage=$(mktemp -d)
    qemu_stage_install "$_qppi_stage"
    install -d "$_qppi_stage/usr/local/lib/rpi-preseed-probe"
    install -d "$_qppi_stage/lib/systemd/system"
    install -m0755 "$QEMU_TESTS/probe/collect.sh" "$_qppi_stage/usr/local/lib/rpi-preseed-probe/collect.sh"
    install -m0644 "$QEMU_TESTS/probe/rpi-preseed-probe.service" "$_qppi_stage/lib/systemd/system/rpi-preseed-probe.service"

    qemu_rootfs_mount "$_qppi_out"
    mkdir -p "$QEMU_ROOTFS_MNT/boot/firmware" \
             "$QEMU_ROOTFS_MNT/var/lib/rpi-preseed" \
             "$QEMU_ROOTFS_MNT/etc/systemd/system/multi-user.target.wants" \
             "$QEMU_ROOTFS_MNT/usr" \
             "$QEMU_ROOTFS_MNT/lib" \
             "$QEMU_ROOTFS_MNT/usr/local/lib"

    cp -a "$_qppi_stage/usr/." "$QEMU_ROOTFS_MNT/usr/"
    cp -a "$_qppi_stage/lib/." "$QEMU_ROOTFS_MNT/lib/"

    _qemu_install_virt_modules "$QEMU_ROOTFS_MNT"
    _qemu_patch_fstab_for_virt "$QEMU_ROOTFS_MNT"
    _qemu_disable_firstboot_blockers "$QEMU_ROOTFS_MNT"
    _qemu_disable_virt_incompatible_services "$QEMU_ROOTFS_MNT"

    ln -sfn /lib/systemd/system/rpi-preseed.service \
        "$QEMU_ROOTFS_MNT/etc/systemd/system/multi-user.target.wants/rpi-preseed.service"
    ln -sfn /lib/systemd/system/rpi-preseed-runcmd-early.service \
        "$QEMU_ROOTFS_MNT/etc/systemd/system/multi-user.target.wants/rpi-preseed-runcmd-early.service"
    ln -sfn /lib/systemd/system/rpi-preseed-runcmd-late.service \
        "$QEMU_ROOTFS_MNT/etc/systemd/system/multi-user.target.wants/rpi-preseed-runcmd-late.service"
    ln -sfn /lib/systemd/system/rpi-preseed-probe.service \
        "$QEMU_ROOTFS_MNT/etc/systemd/system/multi-user.target.wants/rpi-preseed-probe.service"

    qemu_rootfs_umount
    trap - EXIT INT TERM
    rm -rf "$_qppi_stage"
    printf '%s' "$_qppi_key" >"$_qppi_stamp"
    QEMU_PROVISIONED_IMAGE="$_qppi_out"
    qemu_info "base image provisioned at $_qppi_out"
}
