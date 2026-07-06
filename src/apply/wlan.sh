# shellcheck shell=dash
# rpi-preseed applier — [wlan]: NetworkManager preconfigured connection + country.

apply_wlan() {
    toml_present wlan.ssid || return 0
    _aw_ssid=$(toml_get wlan.ssid)
    _aw_pass=$(toml_get_default wlan.password "")
    _aw_country=$(toml_get_default wlan.country "")
    _aw_km=$(wlan_key_mgmt)

    # imager_custom only knows open + WPA2 (wpa-psk); use our native NM writer for
    # WPA3-Personal (sae) and Enhanced Open (owe).
    if imager_available && { [ "$_aw_km" = wpa-psk ] || [ "$_aw_km" = none ]; }; then
        set --
        toml_bool wlan.hidden false && set -- "$@" --hidden
        [ -n "$_aw_pass" ] && ! toml_bool wlan.password_encrypted false && set -- "$@" --plain
        set -- "$@" "$_aw_ssid"
        [ -n "$_aw_pass" ] && set -- "$@" "$_aw_pass"
        [ -n "$_aw_country" ] && set -- "$@" "$_aw_country"
        report_run wlan.ssid imager_custom "$IMAGER_CUSTOM" set_wlan "$@" || return 1
    else
        _apply_wlan_fallback "$_aw_ssid" "$_aw_pass" "$_aw_km"
    fi
    [ -n "$_aw_country" ] && report_key wlan.country applied
    return 0
}

# _apply_wlan_fallback SSID PASS KEYMGMT — write a NetworkManager .nmconnection.
#   none      open network (no [wifi-security] block)
#   owe       WPA3 Enhanced Open (key-mgmt=owe, no passphrase)
#   wpa-psk   WPA2-Personal    | psk carries the passphrase
#   sae       WPA3-Personal    | (PMF left at NM's per-key default)
_apply_wlan_fallback() {
    _awf_ssid="$1"; _awf_pass="$2"; _awf_km="${3:-none}"
    _awf_hidden=false
    toml_bool wlan.hidden false && _awf_hidden=true
    _awf_dir=$(target_path /etc/NetworkManager/system-connections)
    ensure_dir "$_awf_dir" 755
    _awf_file="$_awf_dir/preconfigured.nmconnection"
    {
        printf '[connection]\nid=preconfigured\ntype=wifi\n\n'
        printf '[wifi]\nmode=infrastructure\nssid=%s\nhidden=%s\n\n' "$_awf_ssid" "$_awf_hidden"
        case "$_awf_km" in
            none) : ;;
            owe)  printf '[wifi-security]\nkey-mgmt=owe\n\n' ;;
            *)    printf '[wifi-security]\nkey-mgmt=%s\npsk=%s\n\n' "$_awf_km" "$_awf_pass" ;;
        esac
        printf '[ipv4]\nmethod=auto\n\n[ipv6]\naddr-gen-mode=default\nmethod=auto\n'
    } | atomic_write "$_awf_file"
    chmod 600 "$_awf_file" 2>/dev/null || true
    report_key wlan.ssid applied "fallback"
}
