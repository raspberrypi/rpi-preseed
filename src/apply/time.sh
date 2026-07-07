# shellcheck shell=dash
# rpi-preseed applier — [time]: NTP servers for systemd-timesyncd.
#
# Writes a timesyncd drop-in. The timezone is configured via [locale].timezone;
# this section only sets the NTP/FallbackNTP server lists.

apply_time() {
    toml_present time.ntp || toml_present time.fallback_ntp || return 0
    _at_ntp=$(_time_join time.ntp)
    _at_fb=$(_time_join time.fallback_ntp)
    [ -n "$_at_ntp" ] || [ -n "$_at_fb" ] || return 0

    _at_dir=$(target_path /etc/systemd/timesyncd.conf.d)
    ensure_dir "$_at_dir" 755
    {
        printf '[Time]\n'
        [ -n "$_at_ntp" ] && printf 'NTP=%s\n' "$_at_ntp"
        [ -n "$_at_fb" ] && printf 'FallbackNTP=%s\n' "$_at_fb"
    } | atomic_write "$_at_dir/10-rpi-preseed.conf"

    if helpers_live && have systemctl; then
        systemctl try-restart systemd-timesyncd >/dev/null 2>&1 || true
    fi
    report_key time.ntp applied timesyncd
    log_info "time: NTP servers configured"
    return 0
}

# _time_join KEY — join a TOML array into a single space-separated line.
_time_join() {
    toml_array "$1" | while IFS= read -r _tj_e; do
        [ -n "$_tj_e" ] || continue
        printf '%s ' "$_tj_e"
    done
}
