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

# _apply_keyboard — set the keyboard layout everywhere it must land.
#
# Writing /etc/default/keyboard alone is NOT enough on a desktop image: the
# Wayland compositor (labwc) reads its own environment file, whose packaged
# default layout otherwise wins over the user's choice, so the desktop ignores
# the selected keymap (raspberrypi/trixie-feedback#67). The Imager set_keymap
# path routes through raspi-config's do_configure_keyboard, which already calls
# update_labwc_keyboard; our full-XKB fallback must do that propagation itself.
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
    _apply_labwc_keyboard
    report_key locale.keymap applied "fallback"
}

# _apply_labwc_keyboard — mirror raspi-config's update_labwc_keyboard: push the
# XKB layout into labwc's environment file(s) so the Wayland desktop and greeter
# honour it. labwc does not read /etc/default/keyboard; the per-user override we
# create here takes precedence over the packaged /etc/xdg default that would
# otherwise pin the layout (trixie-feedback#67). Uses the same _ak_* values as
# _apply_keyboard, its only caller.
_apply_labwc_keyboard() {
    # Per-user session environment for UID 1000, resolved from the target's
    # passwd so this works against both a live system and a sandbox rootfs.
    _alk_user=$(first_user)
    _alk_home=$(first_user_home)
    if [ -n "$_alk_home" ]; then
        _labwc_env_write "$(target_path "$_alk_home/.config/labwc/environment")" "$_alk_user"
    fi

    # Greeter (login screen) environment — update in place only if it exists,
    # matching raspi-config; the packaged file lives in one of these locations.
    for _alk_g in /etc/xdg/labwc-greeter/environment /usr/share/labwc/environment; do
        if [ -e "$(target_path "$_alk_g")" ]; then
            _labwc_env_write "$(target_path "$_alk_g")" ""
            break
        fi
    done

    # Reload a running compositor so the change takes effect without a reboot
    # (equivalent to labwc --reconfigure; a no-op before the session starts).
    if helpers_live && have pkill; then
        pkill -HUP -x labwc 2>/dev/null || true
    fi
}

# _labwc_env_write FILE [OWNER] — set the four XKB_DEFAULT_* keys in a labwc
# environment file, preserving any unrelated lines, then (when live and OWNER is
# given) chown it to the session user. Idempotent: re-applying replaces the keys
# rather than appending duplicates.
_labwc_env_write() {
    _lew_file=$1
    _lew_owner=$2
    {
        # Carry over everything except the keys we own, then re-emit them.
        [ -f "$_lew_file" ] && grep -vE '^XKB_DEFAULT_(MODEL|LAYOUT|VARIANT|OPTIONS)=' "$_lew_file"
        printf 'XKB_DEFAULT_MODEL=%s\n' "$_ak_model"
        printf 'XKB_DEFAULT_LAYOUT=%s\n' "$_ak_layout"
        printf 'XKB_DEFAULT_VARIANT=%s\n' "$_ak_variant"
        printf 'XKB_DEFAULT_OPTIONS=%s\n' "$_ak_options"
    } | atomic_write "$_lew_file"
    if helpers_live && [ -n "$_lew_owner" ]; then
        chown "$_lew_owner:$_lew_owner" "$_lew_file" 2>/dev/null || true
    fi
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
