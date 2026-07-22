# shellcheck shell=dash
# Dependency checks for the rootless qemu harness (-M virt + fuse2fs).

qemu_preflight() {
    _pf_ok=0

    if ! qemu_have qemu-system-aarch64; then
        qemu_warn "qemu-system-aarch64 not found (install qemu-system-arm / qemu-system-aarch64)"
        _pf_ok=1
    fi

    for _pf_cmd in fuse2fs qemu-img qemu-storage-daemon mcopy mkinitramfs; do
        if ! qemu_have "$_pf_cmd"; then
            case "$_pf_cmd" in
                fuse2fs) qemu_warn "fuse2fs not found (apt install fuse2fs)" ;;
                mcopy) qemu_warn "mtools (mcopy) not found (apt install mtools)" ;;
                qemu-storage-daemon) qemu_warn "qemu-storage-daemon not found (install qemu-utils / qemu-system)" ;;
                mkinitramfs) qemu_warn "mkinitramfs not found (apt install initramfs-tools; needed for virtio initrd)" ;;
                *) qemu_warn "$_pf_cmd not found" ;;
            esac
            _pf_ok=1
        fi
    done

    if ! qemu_have od || ! qemu_have dd; then
        qemu_warn "dd/od not found (needed to parse MBR partition offsets)"
        _pf_ok=1
    fi

    if ! qemu_have fusermount3 && ! qemu_have fusermount; then
        qemu_warn "fusermount not found (needed to unmount fuse2fs mounts)"
        _pf_ok=1
    fi

    if ! qemu_have sha256sum; then
        qemu_warn "sha256sum not found"
        _pf_ok=1
    fi

    if ! qemu_have curl && ! qemu_have wget; then
        qemu_warn "curl or wget not found (needed to auto-download Pi OS images)"
        if [ -z "${RPI_PRESEED_QEMU_IMAGE:-}" ] && [ -z "${RPI_PRESEED_QEMU_IMAGE_URL:-}" ]; then
            if [ "${RPI_PRESEED_QEMU_AUTO_DOWNLOAD:-1}" != 0 ]; then
                _pf_ok=1
            fi
        fi
    fi

    if [ "$_pf_ok" -ne 0 ]; then
        return 1
    fi

    qemu_info "host arch: $(uname -m)"
    if [ -c /dev/kvm ] 2>/dev/null && [ "$(uname -m)" = aarch64 ]; then
        qemu_info "accel: KVM (-M virt -cpu host)"
    else
        qemu_info "accel: TCG (-M virt; boots will be slower without aarch64 KVM)"
    fi

    return 0
}
