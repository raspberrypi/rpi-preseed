# shellcheck shell=dash
# rpi-preseed applier — [mounts]: persistent filesystem mounts via /etc/fstab.
#
# Each entry is a complete fstab line ("<spec> <mountpoint> <fstype> <options>
# <dump> <pass>"). Lines are appended idempotently; the mountpoint directory is
# created. Mounts take effect on the next boot (no risky auto 'mount -a').

apply_mounts() {
    toml_present mounts.fstab || return 0
    _am_fstab=$(target_path /etc/fstab)
    ensure_dir "$(dirname "$_am_fstab")" 755
    [ -f "$_am_fstab" ] || : >"$_am_fstab"

    _am_added=0
    _am_tmp=$(mktemp); toml_array mounts.fstab >"$_am_tmp"
    while IFS= read -r _am_line; do
        [ -n "$_am_line" ] || continue
        if grep -qxF "$_am_line" "$_am_fstab" 2>/dev/null; then
            continue
        fi
        # Create the mountpoint (field 2) when it is an absolute path.
        _am_mp=$(printf '%s\n' "$_am_line" | awk '{print $2}')
        case "$_am_mp" in
            /*) ensure_dir "$(target_path "$_am_mp")" 755 ;;
        esac
        printf '%s\n' "$_am_line" >>"$_am_fstab"
        _am_added=$((_am_added + 1))
    done <"$_am_tmp"
    rm -f "$_am_tmp"

    if [ "$_am_added" -gt 0 ]; then
        report_key mounts.fstab applied "added $_am_added entry(ies)"
        log_info "mounts: added $_am_added fstab entry(ies)"
    else
        report_key mounts.fstab applied "no change"
    fi
    return 0
}
