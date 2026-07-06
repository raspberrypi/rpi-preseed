# shellcheck shell=dash
# rpi-preseed applier — [wlan]: NetworkManager preconfigured connection + country.

apply_wlan() {
    toml_present wlan.ssid || toml_present wlan.ssid_hex || return 0
    _aw_pass=$(toml_get_default wlan.password "")
    _aw_country=$(toml_get_default wlan.country "")
    _aw_km=$(wlan_key_mgmt)

    # A non-UTF-8 SSID arrives hex-encoded in wlan.ssid_hex (a TOML string can
    # only carry valid UTF-8). Decode it to a NetworkManager byte-array.
    # wlan.ssid_hex takes precedence over wlan.ssid.
    _aw_ssid_bytes=""
    if toml_present wlan.ssid_hex; then
        if ! _aw_ssid_bytes=$(hex_to_nm_bytes "$(toml_get wlan.ssid_hex)"); then
            report_key wlan.ssid_hex failed "invalid hex"
            return 1
        fi
        _aw_ssid=""
    else
        _aw_ssid=$(toml_get wlan.ssid)
    fi

    # We always write the NetworkManager connection ourselves. Our writer is a
    # superset of imager_custom's set_wlan: it produces the same
    # preconfigured.nmconnection for open/WPA2 networks and additionally covers
    # WPA3-Personal (sae), Enhanced Open (owe) and non-UTF-8 (hex) SSIDs, which
    # imager_custom cannot express. That leaves a single connection-writing path.
    _apply_wlan_nm "$_aw_ssid" "$_aw_pass" "$_aw_km" "$_aw_ssid_bytes" || return 1

    # The regulatory domain is a separate concern that imager_custom delegated to
    # raspi-config; do the same on a live device, else persist the kernel
    # regdomain via cmdline.txt so an offline-prepared image still comes up right.
    [ -n "$_aw_country" ] && _apply_wlan_country "$_aw_country"
    return 0
}

# _apply_wlan_country COUNTRY — set the Wi-Fi regulatory domain. On a live device
# defer to raspi-config (which also unblocks rfkill and persists the setting);
# offline, append the kernel regdomain to cmdline.txt so it still applies.
_apply_wlan_country() {
    _awc_country="$1"
    if helpers_live && have "$RASPI_CONFIG"; then
        report_run wlan.country raspi-config "$RASPI_CONFIG" nonint do_wifi_country "$_awc_country"
        return
    fi
    _awc_cmd=$(target_path /boot/firmware/cmdline.txt)
    [ -f "$_awc_cmd" ] || _awc_cmd=$(target_path /boot/cmdline.txt)
    _awc_param="cfg80211.ieee80211_regdom=$_awc_country"
    if [ -f "$_awc_cmd" ]; then
        if ! grep -qwF "$_awc_param" "$_awc_cmd" 2>/dev/null; then
            _awc_cur=$(cat "$_awc_cmd")
            printf '%s %s\n' "$_awc_cur" "$_awc_param" | atomic_write "$_awc_cmd"
        fi
    else
        printf '%s\n' "$_awc_param" | atomic_write "$_awc_cmd"
    fi
    report_key wlan.country applied fallback
}

# _apply_wlan_nm SSID PASS KEYMGMT [SSID_BYTES] — write the preconfigured NM
# .nmconnection. This is the sole connection-writing path (no imager_custom).
#   none      open network (no [wifi-security] block)
#   owe       WPA3 Enhanced Open (key-mgmt=owe, no passphrase)
#   wpa-psk   WPA2-Personal    | psk carries the passphrase
#   sae       WPA3-Personal    | (PMF left at NM's per-key default)
# When SSID_BYTES is set (a decimal byte-array from a hex SSID) it is written in
# place of the plain SSID string, so NetworkManager reconstructs the raw octets.
_apply_wlan_nm() {
    _awf_ssid="$1"; _awf_pass="$2"; _awf_km="${3:-none}"; _awf_bytes="${4:-}"
    _awf_hidden=false
    toml_bool wlan.hidden false && _awf_hidden=true
    _awf_dir=$(target_path /etc/NetworkManager/system-connections)
    ensure_dir "$_awf_dir" 755
    _awf_file="$_awf_dir/preconfigured.nmconnection"
    {
        printf '[connection]\nid=preconfigured\ntype=wifi\n\n'
        if [ -n "$_awf_bytes" ]; then
            printf '[wifi]\nmode=infrastructure\nssid=%s\nhidden=%s\n\n' "$_awf_bytes" "$_awf_hidden"
        else
            printf '[wifi]\nmode=infrastructure\nssid=%s\nhidden=%s\n\n' "$_awf_ssid" "$_awf_hidden"
        fi
        case "$_awf_km" in
            none) : ;;
            owe)  printf '[wifi-security]\nkey-mgmt=owe\n\n' ;;
            *)    printf '[wifi-security]\nkey-mgmt=%s\npsk=%s\n\n' "$_awf_km" "$_awf_pass" ;;
        esac
        printf '[ipv4]\nmethod=auto\n\n[ipv6]\naddr-gen-mode=default\nmethod=auto\n'
    } | atomic_write "$_awf_file"
    chmod 600 "$_awf_file" 2>/dev/null || true
    if [ -n "$_awf_bytes" ]; then
        report_key wlan.ssid_hex applied networkmanager
    else
        report_key wlan.ssid applied networkmanager
    fi
}
