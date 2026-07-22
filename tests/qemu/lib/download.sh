# shellcheck shell=dash
# Download Raspberry Pi OS Lite arm64 images for qemu tests (rootless, cached).

_qemu_download_load_conf() {
    if [ -f "$QEMU_TESTS/pios-image.conf" ]; then
        # shellcheck disable=SC1091
        . "$QEMU_TESTS/pios-image.conf"
    fi
    : "${RPI_PRESEED_QEMU_PIOS_RELEASE:=2026-06-19}"
    : "${RPI_PRESEED_QEMU_PIOS_MIRROR:=https://downloads.raspberrypi.com/raspios_lite_arm64/images}"
    : "${RPI_PRESEED_QEMU_PIOS_MIRROR_FALLBACK:=https://downloads.raspberrypi.org/raspios_lite_arm64/images}"
}

# _qemu_pios_normalize_release RELEASE
_qemu_pios_normalize_release() {
    _qpn="$1"
    case "$_qpn" in
        raspios_lite_arm64-*) ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            _qpn="raspios_lite_arm64-$_qpn"
            ;;
    esac
    printf '%s' "$_qpn"
}

# _qemu_fetch_text_url URL — try primary mirror then fallback.
_qemu_fetch_text_url() {
    _qftu_url="$1"
    if _qftu_body=$(_qemu_fetch_text "$_qftu_url" 2>/dev/null); then
        printf '%s' "$_qftu_body"
        return 0
    fi
    _qftu_fb="${RPI_PRESEED_QEMU_PIOS_MIRROR_FALLBACK:-}"
    _qftu_pri="${RPI_PRESEED_QEMU_PIOS_MIRROR:-}"
    if [ -n "$_qftu_fb" ] && [ "$_qftu_fb" != "$_qftu_pri" ]; then
        _qftu_alt=$(printf '%s' "$_qftu_url" | sed "s|^$(printf '%s' "$_qftu_pri" | sed 's/[\/&]/\\&/g')|$_qftu_fb|")
        _qemu_fetch_text "$_qftu_alt"
        return $?
    fi
    return 1
}

_qemu_download_tool() {
    if qemu_have curl; then
        printf '%s' curl
        return 0
    fi
    if qemu_have wget; then
        printf '%s' wget
        return 0
    fi
    return 1
}

# _qemu_fetch_url URL OUTFILE
_qemu_fetch_url() {
    _qfu_url="$1"
    _qfu_out="$2"
    _qfu_tool=$(_qemu_download_tool) || qemu_die "need curl or wget to download Pi OS images"
    case "$_qfu_tool" in
        curl)
            curl -fsSL --retry 3 --connect-timeout 30 -o "$_qfu_out" "$_qfu_url"
            ;;
        wget)
            wget -q -O "$_qfu_out" "$_qfu_url"
            ;;
    esac
}

# _qemu_fetch_text URL — print response body to stdout.
_qemu_fetch_text() {
    _qft_url="$1"
    _qft_tool=$(_qemu_download_tool) || return 1
    case "$_qft_tool" in
        curl) curl -fsSL --retry 3 --connect-timeout 30 "$_qft_url" ;;
        wget) wget -q -O - "$_qft_url" ;;
    esac
}

# _qemu_pios_resolve_release — print release directory basename.
_qemu_pios_resolve_release() {
    _qpr_release="${RPI_PRESEED_QEMU_PIOS_RELEASE:-2026-06-19}"
    case "$_qpr_release" in
        latest|LATEST)
            _qpr_html=$(_qemu_fetch_text_url "${RPI_PRESEED_QEMU_PIOS_MIRROR}/") || \
                qemu_die "failed to fetch Pi OS release index from ${RPI_PRESEED_QEMU_PIOS_MIRROR}/"
            _qpr_release=$(printf '%s\n' "$_qpr_html" | sed -n \
                's/.*href="\(raspios_lite_arm64-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)\/.*/\1/p' \
                | sort -r | head -n1)
            [ -n "$_qpr_release" ] || qemu_die "could not determine latest Pi OS release from mirror index"
            ;;
    esac
    _qemu_pios_normalize_release "$_qpr_release"
}

# _qemu_pios_image_basename RELEASE — print *.img.xz filename from release directory.
_qemu_pios_image_basename() {
    _qpb_release="$1"
    _qpb_url="${RPI_PRESEED_QEMU_PIOS_MIRROR}/${_qpb_release}/"
    _qpb_html=$(_qemu_fetch_text_url "$_qpb_url") || \
        qemu_die "failed to fetch Pi OS release page $_qpb_url"
    _qpb_name=$(printf '%s\n' "$_qpb_html" | sed -n \
        's/.*href="\([^"/?]*-arm64-lite\.img\.xz\)".*/\1/p' | head -n1)
    [ -n "$_qpb_name" ] || qemu_die "no arm64-lite.img.xz found under $_qpb_url"
    printf '%s' "$_qpb_name"
}

# _qemu_verify_sha256 FILE SHA256FILE
_qemu_verify_sha256() {
    _qvs_file="$1"
    _qvs_sum="$2"
    [ -f "$_qvs_sum" ] || return 0
    _qvs_dir=$(dirname -- "$_qvs_file")
    _qvs_base=$(basename -- "$_qvs_file")
    (
        cd "$_qvs_dir" || exit 1
        sha256sum -c "$_qvs_sum" >/dev/null 2>&1 || {
            _qvs_expected=$(sed -n 's/^[[:space:]]*\([0-9a-fA-F]\{64\}\).*/\1/p' "$_qvs_sum" | head -n1)
            _qvs_got=$(sha256sum "$_qvs_base" | awk '{print $1}')
            [ -n "$_qvs_expected" ] && [ "$_qvs_expected" = "$_qvs_got" ]
        }
    ) || qemu_die "sha256 mismatch for $_qvs_file"
}

# qemu_download_pios_image — download (or reuse cache); print path to .img.xz.
qemu_download_pios_image() {
    _qemu_download_load_conf
    ensure_dir "$RPI_PRESEED_QEMU_CACHE/downloads"

    _qdp_release=$(_qemu_pios_resolve_release)
    _qdp_name=$(_qemu_pios_image_basename "$_qdp_release")
    _qdp_dir="$RPI_PRESEED_QEMU_CACHE/downloads/$_qdp_release"
    _qdp_img="$_qdp_dir/$_qdp_name"
    ensure_dir "$_qdp_dir"

    if [ -f "$_qdp_img" ]; then
        qemu_info "using cached Pi OS image $_qdp_img"
        printf '%s' "$_qdp_img"
        return 0
    fi

    _qdp_base="${RPI_PRESEED_QEMU_PIOS_MIRROR}/${_qdp_release}/${_qdp_name}"
    qemu_info "downloading Pi OS Lite arm64 ($_qdp_release) from $_qdp_base"
    _qdp_tmp="$_qdp_img.partial"
    rm -f "$_qdp_tmp"
    if ! _qemu_fetch_url "$_qdp_base" "$_qdp_tmp" 2>/dev/null; then
        _qdp_fb="${RPI_PRESEED_QEMU_PIOS_MIRROR_FALLBACK:-}"
        _qdp_pri="${RPI_PRESEED_QEMU_PIOS_MIRROR:-}"
        if [ -n "$_qdp_fb" ] && [ "$_qdp_fb" != "$_qdp_pri" ]; then
            _qdp_base=$(printf '%s' "$_qdp_base" | sed "s|^$(printf '%s' "$_qdp_pri" | sed 's/[\/&]/\\&/g')|$_qdp_fb|")
            _qemu_fetch_url "$_qdp_base" "$_qdp_tmp" || qemu_die "download failed: $_qdp_base"
        else
            qemu_die "download failed: $_qdp_base"
        fi
    fi
    mv -f "$_qdp_tmp" "$_qdp_img"

    _qdp_sha_url="${_qdp_base}.sha256"
    _qdp_sha="$_qdp_dir/${_qdp_name}.sha256"
    if _qemu_fetch_text_url "$_qdp_sha_url" >"$_qdp_sha.partial" 2>/dev/null; then
        mv -f "$_qdp_sha.partial" "$_qdp_sha"
        _qemu_verify_sha256 "$_qdp_img" "$_qdp_sha"
        qemu_info "sha256 verified"
    else
        rm -f "$_qdp_sha.partial"
        qemu_warn "no sha256 sidecar at $_qdp_sha_url; skipping checksum verify"
    fi

    printf '%s' "$_qdp_img"
}

# qemu_download_pios_image_cli — standalone entry for `make qemu-download`.
qemu_download_pios_image_cli() {
    _qemu_download_load_conf
    _qdc_path=$(qemu_download_pios_image)
    printf 'Pi OS image: %s\n' "$_qdc_path"
}
