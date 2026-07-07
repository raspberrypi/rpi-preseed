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
    # Anything in [user] triggers this applier. Group/sudo membership can target
    # the primary account on its own, without a rename or password change.
    toml_present user.name || toml_present user.password || \
        toml_present user.passwordless_sudo || toml_present user.groups || return 0

    _au_prev=$(first_user)
    [ -n "$_au_prev" ] || _au_prev=pi

    # Effective account name: the rename target if given, else the current UID
    # 1000 login. Everything downstream (sudo, groups) keys off this so it keeps
    # working whether or not the account is being renamed.
    if toml_present user.name; then
        _au_new=$(toml_get user.name)
    else
        _au_new="$_au_prev"
    fi

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

    # Rename / set-password only when a name is given (the schema requires a name
    # alongside a password). Group and sudo changes below do not touch the login,
    # so they skip the live-user guard.
    if toml_present user.name; then
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
    fi

    if toml_bool user.passwordless_sudo false; then
        _au_sudo=$(target_path "/etc/sudoers.d/010_${_au_new}-nopasswd")
        printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$_au_new" | atomic_write "$_au_sudo"
        chmod 440 "$_au_sudo" 2>/dev/null || true
        report_key user.passwordless_sudo applied
    fi

    if toml_present user.groups; then
        _apply_user_groups "$_au_new"
    fi
}

# _apply_user_groups USER — add USER to each supplementary group in user.groups.
#
# This is what lets Imager (or a hand-written config) grant the operator real
# privileges, most importantly membership of the 'sudo' group so the account can
# run `sudo`. Adding to a group is append-only: primary group and existing
# memberships are preserved. A group that does not exist on this image is warned
# and skipped rather than failing the whole apply, so a typo or an
# image-dependent group (e.g. gpio) never aborts first boot.
_apply_user_groups() {
    _aug_user="$1"
    _aug_added=""; _aug_missing=""; _aug_failed=""
    for _aug_g in $(toml_array user.groups); do
        [ -n "$_aug_g" ] || continue
        if ! _group_exists "$_aug_g"; then
            log_warn "user: group '$_aug_g' does not exist on this image; skipping"
            _aug_missing="${_aug_missing:+$_aug_missing,}$_aug_g"
            continue
        fi
        if _add_user_to_group "$_aug_user" "$_aug_g"; then
            _aug_added="${_aug_added:+$_aug_added,}$_aug_g"
        else
            log_error "user: failed to add '$_aug_user' to group '$_aug_g'"
            _aug_failed="${_aug_failed:+$_aug_failed,}$_aug_g"
        fi
    done
    [ -n "$_aug_added" ]   && report_key user.groups applied "$_aug_added"
    [ -n "$_aug_missing" ] && report_key user.groups skipped "no such group: $_aug_missing"
    if [ -n "$_aug_failed" ]; then
        report_key user.groups failed "$_aug_failed"
        return 1
    fi
    return 0
}

# _group_exists NAME — does group NAME exist on the target?
_group_exists() {
    if [ -z "$RPI_PRESEED_ROOT" ]; then
        getent group "$1" >/dev/null 2>&1
    else
        awk -F: -v g="$1" '$1==g {f=1} END{exit !f}' \
            "$(target_path /etc/group)" 2>/dev/null
    fi
}

# _add_user_to_group USER GROUP — append USER to GROUP's members (idempotent).
_add_user_to_group() {
    _autg_u="$1"; _autg_g="$2"
    if helpers_live; then
        # usermod -aG is append-only and a no-op if already a member.
        usermod -aG "$_autg_g" "$_autg_u"
    else
        _autg_grp=$(target_path /etc/group)
        [ -f "$_autg_grp" ] || return 1
        awk -F: -v u="$_autg_u" -v g="$_autg_g" 'BEGIN{OFS=":"}
            {
                if ($1==g) {
                    found=1; member=0
                    n=split($4, m, ",")
                    for (i=1;i<=n;i++) if (m[i]==u) member=1
                    if (!member) { if ($4=="") $4=u; else $4=$4","u }
                }
                print
            }
            END{ exit !found }' "$_autg_grp" >"$_autg_grp.tmp" 2>/dev/null \
            && mv -f "$_autg_grp.tmp" "$_autg_grp"
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
