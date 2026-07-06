# shellcheck shell=dash
# rpi-preseed applier — [boot]: append lines to config.txt / cmdline.txt.

apply_boot() {
    _ab_cfg=$(target_path /boot/firmware/config.txt)
    [ -f "$_ab_cfg" ] || [ -d "$(dirname "$_ab_cfg")" ] || _ab_cfg=$(target_path /boot/config.txt)

    if toml_present boot.config_txt; then
        ensure_dir "$(dirname "$_ab_cfg")" 755
        toml_array boot.config_txt | while IFS= read -r _ab_line; do
            [ -n "$_ab_line" ] || continue
            [ -f "$_ab_cfg" ] && grep -qxF "$_ab_line" "$_ab_cfg" 2>/dev/null && continue
            printf '%s\n' "$_ab_line" >>"$_ab_cfg"
        done
        report_key boot.config_txt applied
    fi

    if toml_present boot.cmdline_txt; then
        _ab_add=$(toml_get boot.cmdline_txt)
        if [ -n "$_ab_add" ]; then
            _ab_cmd=$(target_path /boot/firmware/cmdline.txt)
            [ -f "$_ab_cmd" ] || _ab_cmd=$(target_path /boot/cmdline.txt)
            if [ -f "$_ab_cmd" ]; then
                # cmdline.txt is a single line; append space-separated.
                _ab_cur=$(cat "$_ab_cmd")
                printf '%s %s\n' "$_ab_cur" "$_ab_add" | atomic_write "$_ab_cmd"
            else
                printf '%s\n' "$_ab_add" | atomic_write "$_ab_cmd"
            fi
            report_key boot.cmdline_txt applied
        fi
    fi
    return 0
}
