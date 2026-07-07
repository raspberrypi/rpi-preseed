# shellcheck shell=dash
# rpi-preseed applier — [ca_certificates]: install extra trusted CA certificates.
#
# Certificates are referenced by file (a PEM cannot be embedded inline because the
# TOML parser carries no newlines). Each file is resolved next to the config on
# the boot partition (or as an absolute path), staged into
# /usr/local/share/ca-certificates, and registered with update-ca-certificates.

apply_certs() {
    toml_present ca_certificates.files || return 0
    _ac_destdir=$(target_path /usr/local/share/ca-certificates)
    ensure_dir "$_ac_destdir" 755

    _ac_staged=0
    _ac_tmp=$(mktemp); toml_array ca_certificates.files >"$_ac_tmp"
    while IFS= read -r _ac_f; do
        [ -n "$_ac_f" ] || continue
        case "$_ac_f" in
            /*) _ac_src="$_ac_f" ;;
            *)  _ac_src="$RPI_PRESEED_BOOT_DIR/$_ac_f" ;;
        esac
        if [ ! -f "$_ac_src" ]; then
            log_warn "ca_certificates: file not found, skipping: $_ac_f"
            report_key ca_certificates skipped "missing: $_ac_f"
            continue
        fi
        # update-ca-certificates only considers *.crt files.
        _ac_name=$(basename "$_ac_f"); _ac_name=${_ac_name%.crt}.crt
        if cp -f "$_ac_src" "$_ac_destdir/$_ac_name" 2>/dev/null; then
            chmod 644 "$_ac_destdir/$_ac_name" 2>/dev/null || true
            _ac_staged=$((_ac_staged + 1))
        else
            log_warn "ca_certificates: failed to stage $_ac_f"
            report_key ca_certificates failed "$_ac_f"
        fi
    done <"$_ac_tmp"
    rm -f "$_ac_tmp"

    [ "$_ac_staged" -gt 0 ] || return 0

    if helpers_live && have update-ca-certificates; then
        report_run ca_certificates update-ca-certificates update-ca-certificates
    else
        report_key ca_certificates applied "staged ($_ac_staged); trust store updates on boot"
    fi
    log_info "ca_certificates: staged $_ac_staged certificate(s)"
    return 0
}
