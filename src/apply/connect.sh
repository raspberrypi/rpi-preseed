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

    if helpers_live && have rpi-connect; then
        rpi-connect on >/dev/null 2>&1 || true
    fi
    report_key connect.enabled applied "$_ac_mode"
}
