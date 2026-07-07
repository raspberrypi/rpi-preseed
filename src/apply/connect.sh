# shellcheck shell=dash
# rpi-preseed applier — [connect]: Raspberry Pi Connect enrolment.
#
# The daemon prefers a hardware device-identity and falls back to auth.key, so we
# only ever need to (optionally) write the token; device-identity needs no flag.

apply_connect() {
    toml_present connect.enabled || return 0
    toml_bool connect.enabled false || { report_key connect.enabled skipped "disabled"; return 0; }

    _ac_mode=$(toml_get_default connect.mode device-identity)
    _ac_user=$(toml_get_default user.name "$(first_user)")
    [ -n "$_ac_user" ] || _ac_user=pi

    if [ "$_ac_mode" = token ]; then
        _ac_token=$(toml_get connect.token)
        _ac_dir=$(target_path "/home/$_ac_user/.config/com.raspberrypi.connect")
        ensure_dir "$_ac_dir" 700
        printf '%s' "$_ac_token" | atomic_write "$_ac_dir/auth.key"
        chmod 600 "$_ac_dir/auth.key" 2>/dev/null || true
        report_key connect.token applied
    fi

    # Record whether the board already carries a firmware device-unique
    # identity. Device-identity enrolment relies on this hardware key, so
    # capturing its presence makes the report actionable ("enabled but no
    # device key" explains why unattended enrolment did nothing).
    _report_connect_device_identity

    if helpers_live && have rpi-connect; then
        rpi-connect on >/dev/null 2>&1 || true
    fi
    report_key connect.enabled applied "$_ac_mode"
}

# _report_connect_device_identity — report presence of the firmware
# device-unique key (used by Raspberry Pi Connect device-identity enrolment),
# probed with rpi-fw-crypto. Diagnostic only: never fails the apply.
#
# The device-unique key lives at key-id 1 and is flagged DEVICE in
# `rpi-fw-crypto get-key-status`. We treat that flag as authoritative for "a
# device identity is present", with a pubkey read-back as a fallback probe in
# case the status text ever changes.
_report_connect_device_identity() {
    if ! helpers_live || ! have rpi-fw-crypto; then
        report_key connect.device_identity unknown "rpi-fw-crypto unavailable"
        return 0
    fi

    _rcdi_status=$(rpi-fw-crypto get-key-status 1 2>/dev/null || true)
    case "$_rcdi_status" in
        *DEVICE*)
            report_key connect.device_identity present "fw-crypto key-id 1 (DEVICE)"
            return 0
            ;;
    esac

    if rpi-fw-crypto pubkey --key-id 1 >/dev/null 2>&1; then
        report_key connect.device_identity present "fw-crypto key-id 1 (pubkey)"
    else
        report_key connect.device_identity absent "no fw-crypto device key"
    fi
}
