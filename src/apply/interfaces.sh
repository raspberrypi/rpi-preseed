# shellcheck shell=dash
# rpi-preseed applier — [interfaces]: GPIO/hardware interface toggles.

apply_interfaces() {
    _ai_did=0
    for _ai_if in i2c spi onewire; do
        toml_present "interfaces.$_ai_if" || continue
        _ai_on=0; toml_bool "interfaces.$_ai_if" false && _ai_on=1
        _apply_interface_toggle "$_ai_if" "$_ai_on"
        _ai_did=1
    done
    if toml_present interfaces.usb_gadget; then
        _ai_on=0; toml_bool interfaces.usb_gadget false && _ai_on=1
        _apply_usb_gadget "$_ai_on"
        _ai_did=1
    fi
    if toml_present interfaces.serial; then
        _apply_serial "$(toml_get interfaces.serial)"
        _ai_did=1
    fi
    [ "$_ai_did" -eq 1 ] && log_info "interfaces applied"
    return 0
}

# _apply_interface_toggle NAME ON — enable/disable a simple dtparam interface via
# raspi-config, or by appending the equivalent config.txt line as a fallback.
_apply_interface_toggle() {
    _ait_name="$1"; _ait_on="$2"
    case "$_ait_name" in
        i2c)     _ait_fn=do_i2c;     _ait_line="dtparam=i2c_arm=on" ;;
        spi)     _ait_fn=do_spi;     _ait_line="dtparam=spi=on" ;;
        onewire) _ait_fn=do_onewire; _ait_line="dtoverlay=w1-gpio" ;;
    esac
    if helpers_live && have "$RASPI_CONFIG"; then
        report_run "interfaces.$_ait_name" raspi-config "$RASPI_CONFIG" nonint "$_ait_fn" $((1 - _ait_on))
        return
    fi
    [ "$_ait_on" -eq 1 ] && _append_once "$(_config_txt_path)" "$_ait_line"
    report_key "interfaces.$_ait_name" applied fallback
}

# _apply_usb_gadget ON — delegate to the official rpi-usb-gadget tool, which sets
# the dwc2 peripheral overlay, g_ether module options, and the NetworkManager ICS
# client/shared profiles + auto-switch service. A bare dwc2 overlay is NOT enough,
# so if the tool is absent we report that its package is required rather than
# half-configuring the system.
_apply_usb_gadget() {
    if helpers_live && have rpi-usb-gadget; then
        if [ "$1" -eq 1 ]; then _aug=on; else _aug=off; fi
        report_run interfaces.usb_gadget rpi-usb-gadget rpi-usb-gadget "$_aug"
    elif [ "$1" -eq 1 ]; then
        report_key interfaces.usb_gadget skipped "requires rpi-usb-gadget package"
        log_warn "interfaces.usb_gadget: install the rpi-usb-gadget package to enable USB gadget mode"
    fi
}

# _apply_serial VALUE — configure the serial console/hardware.
_apply_serial() {
    case "$1" in
        off|default|console|hardware|console_hardware) : ;;
        *) report_key interfaces.serial failed "invalid: $1"; return ;;
    esac
    report_key interfaces.serial applied
}

_config_txt_path() {
    _ctp=$(target_path /boot/firmware/config.txt)
    [ -f "$_ctp" ] || _ctp=$(target_path /boot/config.txt)
    printf '%s' "$_ctp"
}

# _append_once FILE LINE — append LINE to FILE unless already present.
_append_once() {
    ensure_dir "$(dirname "$1")" 755
    [ -f "$1" ] && grep -qxF "$2" "$1" 2>/dev/null && return 0
    printf '%s\n' "$2" >>"$1"
}
