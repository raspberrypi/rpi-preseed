# shellcheck shell=dash
# rpi-preseed applier — [ssh]: enable sshd, password auth, keys, ssh-import-id.

apply_ssh() {
    toml_present ssh.enabled || toml_present ssh.authorized_keys || \
        toml_present ssh.ssh_import_id || return 0

    _ash_enabled=1
    toml_bool ssh.enabled true || _ash_enabled=0

    if imager_available; then
        if toml_bool ssh.password_authentication false; then set -- --pass-auth; else set -- --key-only; fi
        [ "$_ash_enabled" -eq 1 ] || set -- "$@" --disabled
        toml_array ssh.authorized_keys | while IFS= read -r _ash_k; do
            [ -n "$_ash_k" ] && set -- "$@" "$_ash_k"
        done
        report_run ssh.enabled imager_custom "$IMAGER_CUSTOM" enable_ssh "$@"
        _ash_ids=$(toml_array ssh.ssh_import_id | tr '\n' ' ')
        # shellcheck disable=SC2086
        [ -n "$_ash_ids" ] && report_run ssh.ssh_import_id imager_custom "$IMAGER_CUSTOM" import_ssh_id $_ash_ids
    else
        _apply_ssh_fallback "$_ash_enabled"
    fi
}

# _apply_ssh_fallback ENABLED — file-based sandbox fallback.
_apply_ssh_fallback() {
    if [ "$1" -eq 1 ]; then
        : | atomic_write "$(target_path /boot/firmware/ssh)" 2>/dev/null || \
            : | atomic_write "$(target_path /boot/ssh)" 2>/dev/null || true
        report_key ssh.enabled applied "fallback"
    fi
    _asf_sshd=$(target_path /etc/ssh/sshd_config.d/rpi-preseed.conf)
    if toml_bool ssh.password_authentication false; then
        printf 'PasswordAuthentication yes\n' | atomic_write "$_asf_sshd"
    else
        printf 'PasswordAuthentication no\n' | atomic_write "$_asf_sshd"
    fi
    report_key ssh.password_authentication applied "fallback"

    _asf_keys=$(toml_array ssh.authorized_keys)
    if [ -n "$_asf_keys" ]; then
        _asf_user=$(first_user)
        [ -n "$_asf_user" ] || _asf_user=$(toml_get_default user.name pi)
        _asf_home=$(target_path "/home/$_asf_user")
        ensure_dir "$_asf_home/.ssh" 700
        printf '%s\n' "$_asf_keys" >>"$_asf_home/.ssh/authorized_keys"
        chmod 600 "$_asf_home/.ssh/authorized_keys" 2>/dev/null || true
        report_key ssh.authorized_keys applied "fallback"
    fi
    if [ -n "$(toml_array ssh.ssh_import_id)" ]; then
        report_key ssh.ssh_import_id skipped "no network in fallback"
    fi
}
