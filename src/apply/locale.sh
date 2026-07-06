# shellcheck shell=dash
# rpi-preseed applier — [locale]: timezone, keymap (full XKB), locale generation.

apply_locale() {
    _al_did=0

    if toml_present locale.timezone; then
        _al_tz=$(toml_get locale.timezone)
        if imager_available; then
            report_run locale.timezone imager_custom "$IMAGER_CUSTOM" set_timezone "$_al_tz"
        else
            printf '%s\n' "$_al_tz" | atomic_write "$(target_path /etc/timezone)"
            report_key locale.timezone applied fallback
        fi
        _al_did=1
    fi

    if toml_present locale.keymap; then
        _apply_keyboard
        _al_did=1
    fi

    if toml_present locale.locales; then
        _apply_locales
        _al_did=1
    fi

    [ "$_al_did" -eq 1 ] && log_info "locale applied"
    return 0
}

# _apply_keyboard — write /etc/default/keyboard with full XKB control.
_apply_keyboard() {
    _ak_layout=$(toml_get locale.keymap)
    _ak_model=$(toml_get_default locale.keymap_model pc105)
    _ak_variant=$(toml_get_default locale.keymap_variant "")
    _ak_options=$(toml_array locale.keymap_options | paste -sd, - 2>/dev/null)

    # imager_custom only handles a plain layout; fall through for variant/options.
    if imager_available && [ -z "$_ak_variant" ] && [ -z "$_ak_options" ]; then
        report_run locale.keymap imager_custom "$IMAGER_CUSTOM" set_keymap "$_ak_layout"
        return
    fi
    {
        printf 'XKBMODEL="%s"\n' "$_ak_model"
        printf 'XKBLAYOUT="%s"\n' "$_ak_layout"
        printf 'XKBVARIANT="%s"\n' "$_ak_variant"
        printf 'XKBOPTIONS="%s"\n' "$_ak_options"
        printf 'BACKSPACE="guess"\n'
    } | atomic_write "$(target_path /etc/default/keyboard)"
    report_key locale.keymap applied "fallback"
}

# _apply_locales — enable locales in /etc/locale.gen and set /etc/default/locale.
_apply_locales() {
    _algen=$(target_path /etc/locale.gen)
    if [ -f "$_algen" ]; then
        toml_array locale.locales | while IFS= read -r _al_l; do
            [ -n "$_al_l" ] || continue
            sed -i "s/^# *\(${_al_l} .*\)/\1/" "$_algen" 2>/dev/null || true
            grep -q "^${_al_l}" "$_algen" 2>/dev/null || printf '%s UTF-8\n' "$_al_l" >>"$_algen"
        done
    else
        toml_array locale.locales | sed 's/$/ UTF-8/' | atomic_write "$_algen"
    fi
    _al_lang=$(toml_get_default locale.lang "$(toml_array locale.locales | head -n1)")
    {
        printf 'LANG=%s\n' "$_al_lang"
        toml_present locale.lc_time && printf 'LC_TIME=%s\n' "$(toml_get locale.lc_time)"
        toml_present locale.lc_measurement && printf 'LC_MEASUREMENT=%s\n' "$(toml_get locale.lc_measurement)"
    } | atomic_write "$(target_path /etc/default/locale)"
    if helpers_live && have locale-gen; then
        locale-gen >/dev/null 2>&1 || true
    fi
    report_key locale.locales applied
}
