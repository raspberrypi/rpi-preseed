# shellcheck shell=dash
# rpi-preseed applier — [user]: rename the preconfigured user + set password.
#
# The rename is done via the RPi userconf helper, which internally runs
# cancel-rename to wire up login/autologin correctly. A live-user guard (also
# enforced by the systemd unit) prevents renaming an in-use account.

# _uid1000_busy — succeed if UID 1000 currently owns any live process.
_uid1000_busy() {
    [ -z "$RPI_PRESEED_ROOT" ] || return 1
    pgrep -u 1000 >/dev/null 2>&1
}

apply_user() {
    toml_present user.name || return 0
    _au_new=$(toml_get user.name)
    _au_prev=$(first_user)
    [ -n "$_au_prev" ] || _au_prev=pi

    # Resolve the password hash (empty if no password configured).
    _au_hash=""
    if toml_present user.password; then
        _au_pass=$(toml_get user.password)
        if toml_bool user.password_encrypted false; then
            _au_hash="$_au_pass"
        else
            if ! _au_hash=$(hash_password "$_au_pass"); then
                report_key user.password failed "no crypt tool"
                return 1
            fi
        fi
    fi

    if _uid1000_busy; then
        report_key user.name failed "uid 1000 busy"
        log_error "refusing to reconfigure user: UID 1000 has live processes"
        return 1
    fi

    if helpers_live && [ -x "$USERCONF" ]; then
        if "$USERCONF" "$_au_prev" "$_au_new" "$_au_hash"; then
            report_key user.name applied "userconf"
            [ -n "$_au_hash" ] && report_key user.password applied "userconf"
        else
            report_key user.name failed "userconf"; return 1
        fi
    else
        _apply_user_fallback "$_au_prev" "$_au_new" "$_au_hash"
    fi

    if toml_bool user.passwordless_sudo false; then
        _au_sudo=$(target_path "/etc/sudoers.d/010_${_au_new}-nopasswd")
        printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$_au_new" | atomic_write "$_au_sudo"
        chmod 440 "$_au_sudo" 2>/dev/null || true
        report_key user.passwordless_sudo applied
    fi
}

# _apply_user_fallback PREV NEW HASH — sandbox-only edit of passwd/shadow.
_apply_user_fallback() {
    _auf_prev="$1"; _auf_new="$2"; _auf_hash="$3"
    _auf_passwd=$(target_path /etc/passwd)
    _auf_shadow=$(target_path /etc/shadow)
    if [ -f "$_auf_passwd" ] && [ "$_auf_prev" != "$_auf_new" ]; then
        sed -i "s/^$_auf_prev:/$_auf_new:/" "$_auf_passwd" 2>/dev/null || true
    fi
    if [ -n "$_auf_hash" ] && [ -f "$_auf_shadow" ]; then
        # Replace the hash field for the (possibly renamed) user.
        awk -F: -v u="$_auf_new" -v h="$_auf_hash" 'BEGIN{OFS=":"}
            $1==u {$2=h} {print}' "$_auf_shadow" >"$_auf_shadow.tmp" 2>/dev/null \
            && mv -f "$_auf_shadow.tmp" "$_auf_shadow"
    fi
    report_key user.name applied "fallback"
    [ -n "$_auf_hash" ] && report_key user.password applied "fallback"
}
