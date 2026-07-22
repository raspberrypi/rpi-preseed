# shellcheck shell=dash
# Fetch a Debian arm64 (virtio-capable) kernel + build a matching initrd so the
# harness can boot Pi OS under `-M virt` on hosts WITHOUT a native arm64 kernel
# (e.g. x86_64 CI). Fully rootless: `dpkg-deb -x` extraction + a hand-rolled
# cpio/gzip initrd carrying a static arm64 busybox. No install, no root, no loop.
#
# The Pi OS guest ships only Raspberry Pi `*rpt*` kernels, which lack virtio and
# cannot boot `-M virt` — so we always need a *Debian* generic arm64 kernel here.

_qemu_debkernel_load_conf() {
    : "${RPI_PRESEED_QEMU_DEBIAN_MIRROR:=https://deb.debian.org/debian}"
    # Pi OS 2026-06 (trixie) rootfs pairs with a trixie-era Debian kernel.
    : "${RPI_PRESEED_QEMU_DEBIAN_SUITE:=trixie}"
}

# _qemu_deb_packages_stream — print the decompressed main/binary-arm64 Packages
# index to stdout, caching only the compressed (~45M) copy on disk.
_qemu_deb_packages_stream() {
    _dps_dir="$RPI_PRESEED_QEMU_CACHE/debian-kernel"
    _dps_xz="$_dps_dir/Packages.$RPI_PRESEED_QEMU_DEBIAN_SUITE.xz"
    if [ ! -f "$_dps_xz" ]; then
        ensure_dir "$_dps_dir"
        _dps_base="$RPI_PRESEED_QEMU_DEBIAN_MIRROR/dists/$RPI_PRESEED_QEMU_DEBIAN_SUITE/main/binary-arm64"
        qemu_info "fetching Debian arm64 package index (one-time)..."
        if ! _qemu_fetch_url "$_dps_base/Packages.xz" "$_dps_xz.partial" 2>/dev/null; then
            rm -f "$_dps_xz.partial"
            return 1
        fi
        mv -f "$_dps_xz.partial" "$_dps_xz"
    fi
    xz -dc "$_dps_xz"
}

# _qemu_deb_find_pkg REGEX — print "VERSION FILENAME" of the newest binary
# package whose name fully matches REGEX (empty + non-zero if none found).
_qemu_deb_find_pkg() {
    _dfp_re="$1"
    _qemu_deb_packages_stream 2>/dev/null | awk -v re="$_dfp_re" '
        function flush() {
            if (pkg ~ re && ver != "" && fn != "") print ver " " fn
            pkg = ""; ver = ""; fn = ""
        }
        /^Package: /  { flush(); pkg = $2 }
        /^Version: /  { ver = $2 }
        /^Filename: / { fn = $2 }
        /^[[:space:]]*$/ { flush() }
        END { flush() }
    ' | sort -V | tail -n1
}

# _qemu_deb_fetch_busybox WORKDIR — download + extract a static arm64 busybox;
# print the path to the extracted binary. Honours RPI_PRESEED_QEMU_BUSYBOX.
_qemu_deb_fetch_busybox() {
    _fbb_work="$1"
    if [ -n "${RPI_PRESEED_QEMU_BUSYBOX:-}" ] && [ -f "$RPI_PRESEED_QEMU_BUSYBOX" ]; then
        printf '%s' "$RPI_PRESEED_QEMU_BUSYBOX"
        return 0
    fi
    _fbb_pkg=$(_qemu_deb_find_pkg '^busybox-static$')
    [ -n "$_fbb_pkg" ] || _fbb_pkg=$(_qemu_deb_find_pkg '^busybox$')
    if [ -z "$_fbb_pkg" ]; then
        qemu_warn "no busybox-static package in Debian arm64 index"
        return 1
    fi
    _fbb_fn=${_fbb_pkg#* }
    _fbb_deb="$_fbb_work/busybox.deb"
    qemu_info "downloading static arm64 busybox ($_fbb_fn)..."
    if ! _qemu_fetch_url "$RPI_PRESEED_QEMU_DEBIAN_MIRROR/$_fbb_fn" "$_fbb_deb" 2>/dev/null; then
        qemu_warn "failed to download busybox .deb"
        return 1
    fi
    _fbb_root="$_fbb_work/busybox-root"
    mkdir -p "$_fbb_root"
    if ! dpkg-deb -x "$_fbb_deb" "$_fbb_root" 2>/dev/null; then
        qemu_warn "dpkg-deb -x failed for busybox .deb"
        return 1
    fi
    _fbb_bin=$(ls -1 "$_fbb_root"/bin/busybox "$_fbb_root"/usr/bin/busybox 2>/dev/null | head -n1)
    if [ -z "$_fbb_bin" ]; then
        qemu_warn "no busybox binary inside busybox .deb"
        return 1
    fi
    printf '%s' "$_fbb_bin"
}

# _qemu_deb_copy_modules MODDIR DESTDIR — copy the virtio + ext4 module set from
# a kernel /lib/modules/<uname> tree into DESTDIR, decompressing as needed.
# Modules the kernel builds in (=y) simply won't be found — that is fine.
_qemu_deb_copy_modules() {
    _cm_moddir="$1"
    _cm_dest="$2"
    # Names cover the virtio transport/block/net stack plus the ext4 rootfs
    # dependency chain. Anything already built into the kernel is skipped.
    # virtio core/transport (virtio, virtio_ring, virtio_pci) is built into the
    # Debian arm64 kernel, so only leaf drivers + the ext4 rootfs chain are needed.
    # virtio_scsi is deliberately omitted: it needs the SCSI core (we boot off
    # virtio-blk), and shipping it just spams "Unknown symbol scsi_*" at load.
    _cm_want='virtio_mmio virtio_blk virtio_net failover net_failover
              crc16 crc32c_generic crc32c
              mbcache jbd2 ext4'
    for _cm_n in $_cm_want; do
        find "$_cm_moddir" \( -name "${_cm_n}.ko" -o -name "${_cm_n}.ko.zst" \
             -o -name "${_cm_n}.ko.xz" -o -name "${_cm_n}.ko.gz" \) 2>/dev/null |
        while IFS= read -r _cm_f; do
            _cm_bn=$(basename -- "$_cm_f")
            case "$_cm_bn" in
                *.ko.zst) zstd -dqf "$_cm_f" -o "$_cm_dest/${_cm_bn%.zst}" 2>/dev/null || true ;;
                *.ko.xz)  xz -dc "$_cm_f" >"$_cm_dest/${_cm_bn%.xz}" 2>/dev/null || true ;;
                *.ko.gz)  gzip -dc "$_cm_f" >"$_cm_dest/${_cm_bn%.gz}" 2>/dev/null || true ;;
                *.ko)     cp -f "$_cm_f" "$_cm_dest/$_cm_bn" ;;
            esac
        done
    done
}

# _qemu_deb_write_init PATH — emit the initrd /init (loads virtio, pivots root).
_qemu_deb_write_init() {
    cat >"$1" <<'INIT'
#!/bin/busybox sh
# Minimal virtio initrd for `-M virt`: load modules, mount root, switch_root.
/bin/busybox mkdir -p /proc /sys /dev /newroot
/bin/busybox mount -t proc proc /proc 2>/dev/null
/bin/busybox mount -t sysfs sysfs /sys 2>/dev/null
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || /bin/busybox mdev -s

# Several passes so module load order sorts itself out without depmod metadata.
_pass=0
while [ "$_pass" -lt 5 ]; do
    for _ko in /modules/*.ko; do
        [ -e "$_ko" ] || continue
        /bin/busybox insmod "$_ko" 2>/dev/null
    done
    _pass=$((_pass + 1))
done

root=/dev/vda2
for _a in $(/bin/busybox cat /proc/cmdline 2>/dev/null); do
    case "$_a" in root=*) root=${_a#root=} ;; esac
done
case "$root" in
    UUID=*)  root="/dev/disk/by-uuid/${root#UUID=}" ;;
    LABEL=*) root="/dev/disk/by-label/${root#LABEL=}" ;;
esac

_i=0
while [ "$_i" -lt 20 ]; do
    [ -b "$root" ] && break
    /bin/busybox sleep 1
    _i=$((_i + 1))
done

if [ ! -b "$root" ]; then
    echo "virtio-initrd: root device '$root' never appeared" >&2
    exec /bin/busybox sh
fi
if ! /bin/busybox mount -o rw "$root" /newroot; then
    echo "virtio-initrd: mounting '$root' failed" >&2
    exec /bin/busybox sh
fi
exec /bin/busybox switch_root /newroot /sbin/init
INIT
    chmod 0755 "$1"
}

# _qemu_deb_make_initrd MODDIR BUSYBOX OUT — assemble the cpio/gzip initrd.
_qemu_deb_make_initrd() {
    _mi_moddir="$1"
    _mi_bb="$2"
    _mi_out="$3"
    _mi_root=$(mktemp -d)
    mkdir -p "$_mi_root/bin" "$_mi_root/modules" \
             "$_mi_root/proc" "$_mi_root/sys" "$_mi_root/dev" "$_mi_root/newroot"

    cp -f "$_mi_bb" "$_mi_root/bin/busybox"
    chmod 0755 "$_mi_root/bin/busybox"
    ( cd "$_mi_root" && ln -sf busybox bin/sh )

    _qemu_deb_copy_modules "$_mi_moddir" "$_mi_root/modules"
    _qemu_deb_write_init "$_mi_root/init"

    _mi_tmp="$_mi_out.partial"
    if ! ( cd "$_mi_root" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) >"$_mi_tmp"; then
        rm -rf "$_mi_root" "$_mi_tmp"
        qemu_warn "cpio/gzip initrd assembly failed"
        return 1
    fi
    mv -f "$_mi_tmp" "$_mi_out"
    rm -rf "$_mi_root"
}

# _qemu_deb_build KERNEL_FILENAME OUTDIR — download + extract the kernel .deb and
# build OUTDIR/vmlinuz + OUTDIR/initrd-virtio.img. Non-zero on any failure.
_qemu_deb_build() {
    _bd_fn="$1"
    _bd_out="$2"
    _bd_work=$(mktemp -d)

    _bd_deb="$_bd_work/linux-image.deb"
    qemu_info "downloading Debian arm64 kernel .deb ($_bd_fn)..."
    if ! _qemu_fetch_url "$RPI_PRESEED_QEMU_DEBIAN_MIRROR/$_bd_fn" "$_bd_deb" 2>/dev/null; then
        rm -rf "$_bd_work"
        qemu_warn "failed to download kernel .deb"
        return 1
    fi

    _bd_kroot="$_bd_work/kernel-root"
    mkdir -p "$_bd_kroot"
    if ! dpkg-deb -x "$_bd_deb" "$_bd_kroot" 2>/dev/null; then
        rm -rf "$_bd_work"
        qemu_warn "dpkg-deb -x failed for kernel .deb"
        return 1
    fi

    _bd_vmlinuz=$(ls -1 "$_bd_kroot"/boot/vmlinuz-* "$_bd_kroot"/usr/lib/modules/*/vmlinuz 2>/dev/null | head -n1)
    # Merged-usr .debs ship modules under /usr/lib/modules; older ones under /lib.
    _bd_moddir=$(ls -1d "$_bd_kroot"/usr/lib/modules/*/ "$_bd_kroot"/lib/modules/*/ 2>/dev/null | head -n1)
    if [ -z "$_bd_vmlinuz" ] || [ -z "$_bd_moddir" ]; then
        rm -rf "$_bd_work"
        qemu_warn "kernel .deb missing vmlinuz or /lib/modules"
        return 1
    fi

    _bd_bb=$(_qemu_deb_fetch_busybox "$_bd_work") || { rm -rf "$_bd_work"; return 1; }

    qemu_info "assembling virtio initrd for $(basename -- "$_bd_moddir")..."
    if ! _qemu_deb_make_initrd "$_bd_moddir" "$_bd_bb" "$_bd_out/initrd-virtio.img"; then
        rm -rf "$_bd_work"
        return 1
    fi
    cp -f "$_bd_vmlinuz" "$_bd_out/vmlinuz"

    # Cache the module tree + a depmod-generated dep table. The guest rootfs only
    # ships the Pi kernel's modules, but we boot the Debian kernel (different
    # uname) — provisioning installs vfat/nls from here so /boot/firmware mounts.
    _bd_uname=$(basename -- "$_bd_moddir")
    _bd_modroot="$_bd_out/modroot"
    rm -rf "$_bd_modroot"
    mkdir -p "$_bd_modroot/lib/modules"
    cp -a "$_bd_moddir" "$_bd_modroot/lib/modules/$_bd_uname"
    if qemu_have depmod; then
        depmod -b "$_bd_modroot" "$_bd_uname" 2>/dev/null || \
            qemu_warn "depmod failed for $_bd_uname; guest vfat autoload may not work"
    else
        qemu_warn "depmod not found; guest vfat autoload may not work"
    fi
    printf '%s' "$_bd_uname" >"$_bd_out/uname"

    rm -rf "$_bd_work"
}

# qemu_resolve_debian_virt_kernel — print "KERNEL INITRD" for -M virt, fetching
# + building (once, cached) a Debian arm64 kernel when the host has none.
qemu_resolve_debian_virt_kernel() {
    _qemu_debkernel_load_conf
    _dvk_root="$RPI_PRESEED_QEMU_CACHE/debian-kernel"
    ensure_dir "$_dvk_root"
    _dvk_stamp="$_dvk_root/resolved.$RPI_PRESEED_QEMU_DEBIAN_SUITE"

    if [ -f "$_dvk_stamp" ]; then
        read -r _dvk_ver _dvk_fn <"$_dvk_stamp" || true
        _dvk_dir="$_dvk_root/$_dvk_ver"
        if [ -n "${_dvk_ver:-}" ] && [ -f "$_dvk_dir/vmlinuz" ] && [ -f "$_dvk_dir/initrd-virtio.img" ]; then
            _dvk_uname=$(cat "$_dvk_dir/uname" 2>/dev/null || true)
            printf '%s %s %s %s' "$_dvk_dir/vmlinuz" "$_dvk_dir/initrd-virtio.img" \
                "$_dvk_dir/modroot/lib/modules/$_dvk_uname" "$_dvk_uname"
            return 0
        fi
    fi

    # Prefer the -unsigned image (vmlinuz + modules in one .deb, no signing dep);
    # fall back to the signed generic arm64 flavour. The `[^ -]*` on the version
    # segment excludes the rt/cloud flavours (which insert `-rt`/`-cloud` before
    # `-arm64`), and the exact `-arm64` tail excludes the 16k/dbg variants.
    _dvk_pkg=$(_qemu_deb_find_pkg '^linux-image-[0-9][^ -]*-arm64-unsigned$')
    [ -n "$_dvk_pkg" ] || _dvk_pkg=$(_qemu_deb_find_pkg '^linux-image-[0-9][^ -]*-arm64$')
    if [ -z "$_dvk_pkg" ]; then
        qemu_warn "no linux-image-*-arm64 package found in Debian $RPI_PRESEED_QEMU_DEBIAN_SUITE index"
        return 1
    fi
    _dvk_ver=${_dvk_pkg%% *}
    _dvk_fn=${_dvk_pkg#* }
    _dvk_dir="$_dvk_root/$_dvk_ver"
    ensure_dir "$_dvk_dir"

    if [ ! -f "$_dvk_dir/vmlinuz" ] || [ ! -f "$_dvk_dir/initrd-virtio.img" ]; then
        _qemu_deb_build "$_dvk_fn" "$_dvk_dir" || return 1
    fi

    printf '%s %s\n' "$_dvk_ver" "$_dvk_fn" >"$_dvk_stamp"
    _dvk_uname=$(cat "$_dvk_dir/uname" 2>/dev/null || true)
    printf '%s %s %s %s' "$_dvk_dir/vmlinuz" "$_dvk_dir/initrd-virtio.img" \
        "$_dvk_dir/modroot/lib/modules/$_dvk_uname" "$_dvk_uname"
}
