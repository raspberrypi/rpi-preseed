# shellcheck shell=dash
# rpi-preseed applier — [system]: hostname.

apply_system() {
    toml_present system.hostname || return 0
    _as_h=$(toml_get system.hostname)
    [ -n "$_as_h" ] || { report_key system.hostname skipped empty; return 0; }

    if imager_available; then
        report_run system.hostname imager_custom "$IMAGER_CUSTOM" set_hostname "$_as_h"
    else
        printf '%s\n' "$_as_h" | atomic_write "$(target_path /etc/hostname)"
        _as_hosts=$(target_path /etc/hosts)
        if [ -f "$_as_hosts" ]; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$_as_h/" "$_as_hosts" 2>/dev/null \
                || printf '127.0.1.1\t%s\n' "$_as_h" >>"$_as_hosts"
        else
            printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$_as_h" | atomic_write "$_as_hosts"
        fi
        report_key system.hostname applied fallback
    fi
    log_info "hostname set"
}
