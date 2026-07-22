# shellcheck shell=dash
# Pi OS image preparation + Debian virtio kernel/initrd resolution.

# Paths set by qemu_prepare_image:
#   QEMU_PREPARED_IMAGE  QEMU_KERNEL  QEMU_INITRD
#   QEMU_KERNEL_UNAME    QEMU_KERNEL_MODULES  (boot kernel's `uname -r` + module tree,
#   so provisioning can install vfat/nls into the guest for -M virt /boot/firmware)
export QEMU_PREPARED_IMAGE QEMU_KERNEL QEMU_INITRD QEMU_KERNEL_UNAME QEMU_KERNEL_MODULES
QEMU_PREPARED_IMAGE=
QEMU_KERNEL=
QEMU_INITRD=
QEMU_KERNEL_UNAME=
QEMU_KERNEL_MODULES=

_qemu_resolve_input() {
    if [ -n "${RPI_PRESEED_QEMU_IMAGE:-}" ] && [ -f "$RPI_PRESEED_QEMU_IMAGE" ]; then
        printf '%s' "$RPI_PRESEED_QEMU_IMAGE"
        return 0
    fi
    if [ -n "${RPI_PRESEED_QEMU_IMAGE:-}" ] && [ -f "${RPI_PRESEED_QEMU_IMAGE}.xz" ]; then
        printf '%s.xz' "$RPI_PRESEED_QEMU_IMAGE"
        return 0
    fi
    if [ -n "${RPI_PRESEED_QEMU_IMAGE_URL:-}" ]; then
        _qri_cache="$RPI_PRESEED_QEMU_CACHE/downloads/url"
        ensure_dir "$_qri_cache"
        _qri_name=$(basename -- "$RPI_PRESEED_QEMU_IMAGE_URL")
        _qri_path="$_qri_cache/$_qri_name"
        if [ ! -f "$_qri_path" ]; then
            qemu_info "downloading Pi OS image from RPI_PRESEED_QEMU_IMAGE_URL"
            _qri_tmp="$_qri_path.partial"
            _qemu_fetch_url "$RPI_PRESEED_QEMU_IMAGE_URL" "$_qri_tmp" || \
                qemu_die "download failed: $RPI_PRESEED_QEMU_IMAGE_URL"
            mv -f "$_qri_tmp" "$_qri_path"
        fi
        printf '%s' "$_qri_path"
        return 0
    fi
    if [ "${RPI_PRESEED_QEMU_AUTO_DOWNLOAD:-1}" != 0 ]; then
        _qri_auto=$(qemu_download_pios_image) || return 1
        printf '%s' "$_qri_auto"
        return 0
    fi
    return 1
}

_qemu_decompress_if_needed() {
    _qd_src="$1"
    _qd_dst="$2"
    case "$_qd_src" in
        *.xz)
            if ! qemu_have xz; then
                qemu_die "need xz to decompress $_qd_src"
            fi
            qemu_info "decompressing $(basename -- "$_qd_src")..."
            xz -dkc "$_qd_src" >"$_qd_dst"
            ;;
        *)
            cp -f "$_qd_src" "$_qd_dst"
            ;;
    esac
}

# qemu_boot_partition_start IMAGE — start sector of the FAT boot partition (mapped file).
qemu_boot_partition_start() {
    qemu_part_start_sectors "$1" 1
}

# qemu_plant_config IMAGE CONFIG_TOML — write rpi-preseed.toml onto the FAT boot partition.
qemu_plant_config() {
    _qpc_img="$1"
    _qpc_cfg="$2"
    if ! qemu_have mcopy; then
        qemu_die "need mtools (mcopy) to plant config on the FAT boot partition"
    fi
    # Important: call qemu_disk_map in this shell (not $(...)) so QEMU_DISK_MAP_PID
    # is set and qemu_disk_unmap can release the qcow2 write lock.
    qemu_disk_map "$_qpc_img"
    _qpc_start=$(qemu_part_start_sectors "$QEMU_DISK_MAP" 1)
    mcopy -o -i "${QEMU_DISK_MAP}@@${_qpc_start}s" "$_qpc_cfg" ::/rpi-preseed.toml
    qemu_disk_unmap
}

# qemu_clone_scenario SRC DST — copy-on-write clone when qemu-img is available.
qemu_clone_scenario() {
    _qcs_src="$1"
    _qcs_dst="$2"
    rm -f "$_qcs_dst"
    if qemu_have qemu-img; then
        _qcs_fmt=raw
        case "$_qcs_src" in
            *.qcow2) _qcs_fmt=qcow2 ;;
        esac
        qemu-img create -f qcow2 -o "backing_file=$_qcs_src,backing_fmt=$_qcs_fmt" "$_qcs_dst" >/dev/null
    else
        cp -f "$_qcs_src" "$_qcs_dst"
    fi
}

_qemu_grow_image() {
    _qg_img="$1"
    qemu_info "growing image by 1G for virt test headroom..."
    if ! qemu_have qemu-img; then
        qemu_warn "qemu-img not found; skipping image grow"
        return 0
    fi
    qemu-img resize "$_qg_img" +1G 2>/dev/null || true
    if qemu_have sfdisk; then
        printf ',+\n' | sfdisk --force --no-reread -N 2 "$_qg_img" >/dev/null 2>&1 || \
            qemu_warn "sfdisk partition grow failed"
    fi
    _qg_start=$(qemu_part_start_sectors "$_qg_img" 2)
    _qg_off=$((_qg_start * 512))
    _qg_resized=0
    if qemu_have losetup && qemu_have resize2fs && qemu_have e2fsck; then
        _qg_loop=$(losetup -f --show -o "$_qg_off" "$_qg_img" 2>/dev/null || true)
        if [ -n "$_qg_loop" ] && [ -b "$_qg_loop" ]; then
            e2fsck -f -p "$_qg_loop" >/dev/null 2>&1 || e2fsck -f -y "$_qg_loop" >/dev/null 2>&1 || true
            if resize2fs "$_qg_loop" >/dev/null 2>&1; then
                _qg_resized=1
                qemu_info "expanded ext4 rootfs on partition 2"
            else
                qemu_warn "resize2fs on loop device failed; rootfs may still be full"
            fi
            losetup -d "$_qg_loop" 2>/dev/null || true
        else
            qemu_warn "losetup unavailable (need root/CAP_SYS_ADMIN); trying fuse2fs resize"
        fi
    fi
    if [ "$_qg_resized" -eq 0 ] && qemu_have fuse2fs && qemu_have resize2fs; then
        _qg_mnt=$(mktemp -d)
        if fuse2fs -o "offset=$_qg_off,fakeroot,rw" "$_qg_img" "$_qg_mnt" 2>/dev/null; then
            # resize2fs needs a block device, not a FUSE mount point — warn only.
            qemu_warn "fuse2fs mount ok but resize2fs needs losetup; rootfs may still be full"
            if qemu_have fusermount3; then
                fusermount3 -u "$_qg_mnt" 2>/dev/null || true
            elif qemu_have fusermount; then
                fusermount -u "$_qg_mnt" 2>/dev/null || true
            fi
        else
            qemu_warn "fuse2fs grow mount failed; rootfs may still be full"
        fi
        rmdir "$_qg_mnt" 2>/dev/null || true
    fi
}

# _qemu_pick_host_virt_kernel — prefer Debian linux-image-arm64 (has virtio).
# Raspberry Pi `*rpt*` kernels lack virtio and cannot boot -M virt.
# Prints: KERNEL_PATH INITRD_PATH
_qemu_pick_host_virt_kernel() {
    _phk_k=
    _phk_i=
    for _phk_cand in $(ls -1 /boot/vmlinuz-*-arm64 2>/dev/null | sort -V); do
        case "$_phk_cand" in
            *rpt*) continue ;;
        esac
        _phk_ver=$(basename -- "$_phk_cand" | sed 's/^vmlinuz-//')
        if [ -f "/boot/initrd.img-$_phk_ver" ]; then
            _phk_k="$_phk_cand"
            _phk_i="/boot/initrd.img-$_phk_ver"
        fi
    done
    if [ -n "$_phk_k" ] && [ -n "$_phk_i" ]; then
        printf '%s %s' "$_phk_k" "$_phk_i"
        return 0
    fi
    return 1
}

# _qemu_ensure_virtio_initrd KERNEL_PATH — return a cached initrd with virtio-blk/pci.
# Host MODULES=dep initrds (common on Pi OS hosts) omit virtio and cannot boot -M virt.
_qemu_ensure_virtio_initrd() {
    _evi_kernel="$1"
    _evi_ver=$(basename -- "$_evi_kernel" | sed 's/^vmlinuz-//')
    _evi_cache="$RPI_PRESEED_QEMU_CACHE/kernels/$_evi_ver"
    _evi_out="$_evi_cache/initrd-virtio.img"
    ensure_dir "$_evi_cache"

    if [ -n "${RPI_PRESEED_QEMU_INITRD:-}" ] && [ -f "$RPI_PRESEED_QEMU_INITRD" ]; then
        printf '%s' "$RPI_PRESEED_QEMU_INITRD"
        return 0
    fi

    if [ -f "$_evi_out" ] && [ "$_evi_out" -nt "$_evi_kernel" ]; then
        printf '%s' "$_evi_out"
        return 0
    fi

    if ! qemu_have mkinitramfs; then
        qemu_die "need mkinitramfs (initramfs-tools) to build a virtio initrd for -M virt"
    fi
    if [ ! -d "/lib/modules/$_evi_ver" ]; then
        qemu_die "missing /lib/modules/$_evi_ver — install linux-image-arm64 matching $_evi_kernel"
    fi

    qemu_info "building virtio initrd for $_evi_ver (one-time; MODULES=list)..."
    _evi_conf=$(mktemp -d)
    mkdir -p "$_evi_conf/conf.d" "$_evi_conf/scripts"
    cat >"$_evi_conf/initramfs.conf" <<'EOF'
MODULES=list
BUSYBOX=auto
COMPRESS=zstd
EOF
    cat >"$_evi_conf/modules" <<'EOF'
virtio_pci
virtio_mmio
virtio_blk
virtio_net
virtio_console
ext4
fat
vfat
nls_cp437
nls_ascii
EOF
    # Copy host hooks/scripts so the usual Debian initramfs content is present.
    if [ -d /etc/initramfs-tools ]; then
        cp -a /etc/initramfs-tools/hooks "$_evi_conf/" 2>/dev/null || true
        cp -a /etc/initramfs-tools/scripts "$_evi_conf/" 2>/dev/null || true
        cp -a /etc/initramfs-tools/conf.d/. "$_evi_conf/conf.d/" 2>/dev/null || true
    fi

    _evi_tmp="$_evi_out.partial"
    if ! mkinitramfs -d "$_evi_conf" -o "$_evi_tmp" "$_evi_ver" >/dev/null; then
        rm -rf "$_evi_conf" "$_evi_tmp"
        qemu_die "mkinitramfs failed building virtio initrd for $_evi_ver"
    fi
    rm -rf "$_evi_conf"
    mv -f "$_evi_tmp" "$_evi_out"
    printf '%s' "$_evi_out"
}

# qemu_resolve_virt_kernel — set QEMU_KERNEL + QEMU_INITRD for -M virt.
qemu_resolve_virt_kernel() {
    if [ -n "${RPI_PRESEED_QEMU_KERNEL:-}" ] && [ -f "$RPI_PRESEED_QEMU_KERNEL" ]; then
        QEMU_KERNEL="$RPI_PRESEED_QEMU_KERNEL"
    fi
    if [ -n "${RPI_PRESEED_QEMU_INITRD:-}" ] && [ -f "$RPI_PRESEED_QEMU_INITRD" ]; then
        QEMU_INITRD="$RPI_PRESEED_QEMU_INITRD"
    fi

    if [ -z "$QEMU_KERNEL" ] || [ -z "$QEMU_INITRD" ]; then
        if _rvk_pair=$(_qemu_pick_host_virt_kernel); then
            # shellcheck disable=SC2086
            set -- $_rvk_pair
            QEMU_KERNEL=${QEMU_KERNEL:-$1}
            # Host initrd is typically MODULES=dep without virtio on Pi hosts —
            # ignore it (rebuilt below) unless RPI_PRESEED_QEMU_INITRD was set.
            if [ -z "$QEMU_INITRD" ]; then
                QEMU_INITRD=
            fi
            QEMU_KERNEL_UNAME=$(basename -- "$QEMU_KERNEL" | sed 's/^vmlinuz-//')
            QEMU_KERNEL_MODULES="/lib/modules/$QEMU_KERNEL_UNAME"
        elif [ "${RPI_PRESEED_QEMU_AUTO_DOWNLOAD:-1}" != 0 ]; then
            # No native arm64 kernel (e.g. x86_64 host): fetch a Debian arm64
            # kernel + build a matching virtio initrd, and cache its module tree
            # (kernel initrd moddir uname) so the guest can mount vfat /boot/firmware.
            qemu_info "no host arm64 kernel; fetching Debian arm64 virt kernel..."
            _rvk_pair=$(qemu_resolve_debian_virt_kernel) || \
                qemu_die "could not obtain a Debian arm64 virt kernel; set RPI_PRESEED_QEMU_KERNEL and RPI_PRESEED_QEMU_INITRD"
            # shellcheck disable=SC2086
            set -- $_rvk_pair
            QEMU_KERNEL=${QEMU_KERNEL:-$1}
            QEMU_INITRD=${QEMU_INITRD:-$2}
            QEMU_KERNEL_MODULES=${3:-}
            QEMU_KERNEL_UNAME=${4:-}
        else
            qemu_die "need a virtio-capable aarch64 kernel: install linux-image-arm64, set RPI_PRESEED_QEMU_KERNEL and RPI_PRESEED_QEMU_INITRD, or enable auto-download"
        fi
    fi

    # Best-effort module tree for an explicitly-overridden kernel.
    if [ -z "$QEMU_KERNEL_UNAME" ]; then
        QEMU_KERNEL_UNAME=$(basename -- "$QEMU_KERNEL" | sed 's/^vmlinuz-//')
    fi
    if [ -z "$QEMU_KERNEL_MODULES" ] && [ -d "/lib/modules/$QEMU_KERNEL_UNAME" ]; then
        QEMU_KERNEL_MODULES="/lib/modules/$QEMU_KERNEL_UNAME"
    fi

    case "$QEMU_KERNEL" in
        *rpt*)
            qemu_die "kernel $QEMU_KERNEL is a Raspberry Pi build (no virtio); use linux-image-arm64"
            ;;
    esac

    if [ -z "$QEMU_INITRD" ]; then
        QEMU_INITRD=$(_qemu_ensure_virtio_initrd "$QEMU_KERNEL")
    fi

    qemu_info "using virt kernel $(basename -- "$QEMU_KERNEL") + $(basename -- "$QEMU_INITRD")"
}

# qemu_prepare_image — populate QEMU_PREPARED_IMAGE, QEMU_KERNEL, QEMU_INITRD.
qemu_prepare_image() {
    _qpi_src=$(_qemu_resolve_input) || \
        qemu_die "no Pi OS image: set RPI_PRESEED_QEMU_IMAGE, RPI_PRESEED_QEMU_IMAGE_URL, or enable auto-download (default)"

    ensure_dir "$RPI_PRESEED_QEMU_CACHE"
    _qpi_hash=$(sha256_file "$_qpi_src")
    _qpi_cache_dir="$RPI_PRESEED_QEMU_CACHE/$_qpi_hash"
    _qpi_prepared="$_qpi_cache_dir/prepared.img"
    ensure_dir "$_qpi_cache_dir"

    qemu_resolve_virt_kernel

    if [ -f "$_qpi_prepared" ]; then
        QEMU_PREPARED_IMAGE="$_qpi_prepared"
        qemu_info "using cached prepared image $_qpi_prepared"
        # One-time grow for virt (older caches may be tight).
        _qpi_grown="$_qpi_cache_dir/grown.stamp"
        if [ ! -f "$_qpi_grown" ]; then
            _qemu_grow_image "$_qpi_prepared"
            touch "$_qpi_grown"
            rm -f "$_qpi_cache_dir/provisioned.qcow2" "$_qpi_cache_dir/provisioned.stamp"
        fi
        return 0
    fi

    qemu_info "preparing image from $_qpi_src (one-time; cached at $_qpi_cache_dir)"
    _qpi_tmp="$_qpi_cache_dir/source.img"
    if [ ! -f "$_qpi_tmp" ]; then
        _qemu_decompress_if_needed "$_qpi_src" "$_qpi_tmp"
    else
        qemu_info "using cached decompressed source.img"
    fi

    qemu_info "copying source.img -> prepared.img"
    cp -f "$_qpi_tmp" "$_qpi_prepared"
    _qemu_grow_image "$_qpi_prepared"
    touch "$_qpi_cache_dir/grown.stamp"

    QEMU_PREPARED_IMAGE="$_qpi_prepared"
    qemu_info "image prep complete"
}
