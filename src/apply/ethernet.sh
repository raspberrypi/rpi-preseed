# shellcheck shell=dash
# rpi-preseed applier — [ethernet]: a single wired NetworkManager connection.
#
# The flat TOML model carries one wired profile (DHCP, static or disabled). It is
# written as a NetworkManager keyfile in the base phase (no network needed),
# mirroring the [wlan] writer.

apply_ethernet() {
    toml_present ethernet.method || toml_present ethernet.address \
        || toml_present ethernet.interface || return 0
    _ae_method=$(toml_get_default ethernet.method dhcp)
    _ae_iface=$(toml_get_default ethernet.interface "")

    _ae_dir=$(target_path /etc/NetworkManager/system-connections)
    ensure_dir "$_ae_dir" 755
    _ae_file="$_ae_dir/preconfigured-ethernet.nmconnection"
    {
        printf '[connection]\nid=preconfigured-ethernet\ntype=ethernet\n'
        [ -n "$_ae_iface" ] && printf 'interface-name=%s\n' "$_ae_iface"
        printf '\n[ethernet]\n\n'
        _apply_ethernet_ipv4 "$_ae_method"
        _apply_ethernet_ipv6 "$_ae_method"
    } | atomic_write "$_ae_file"
    chmod 600 "$_ae_file" 2>/dev/null || true
    report_key ethernet.method applied networkmanager
    log_info "ethernet connection written ($_ae_method)"
    return 0
}

# _apply_ethernet_ipv4 METHOD — emit the [ipv4] keyfile block.
_apply_ethernet_ipv4() {
    case "$1" in
        disabled)
            printf '[ipv4]\nmethod=disabled\n\n'
            return ;;
        static)
            _aei_addr=$(toml_get_default ethernet.address "")
            _aei_gw=$(toml_get_default ethernet.gateway "")
            printf '[ipv4]\nmethod=manual\n'
            if [ -n "$_aei_gw" ]; then
                printf 'address1=%s,%s\n' "$_aei_addr" "$_aei_gw"
            else
                printf 'address1=%s\n' "$_aei_addr"
            fi
            _aei_dns=$(_nm_semicolon_list ethernet.dns)
            [ -n "$_aei_dns" ] && printf 'dns=%s\n' "$_aei_dns"
            _aei_search=$(_nm_semicolon_list ethernet.dns_search)
            [ -n "$_aei_search" ] && printf 'dns-search=%s\n' "$_aei_search"
            printf '\n' ;;
        *)  # dhcp (default)
            printf '[ipv4]\nmethod=auto\n\n' ;;
    esac
}

# _apply_ethernet_ipv6 METHOD — emit the [ipv6] keyfile block.
_apply_ethernet_ipv6() {
    case "$1" in
        disabled) printf '[ipv6]\naddr-gen-mode=default\nmethod=disabled\n' ;;
        *)        printf '[ipv6]\naddr-gen-mode=default\nmethod=auto\n' ;;
    esac
}

# _nm_semicolon_list KEY — join a TOML array into a NetworkManager list ("a;b;").
_nm_semicolon_list() {
    toml_array "$1" | while IFS= read -r _nsl_e; do
        [ -n "$_nsl_e" ] || continue
        printf '%s;' "$_nsl_e"
    done
}
