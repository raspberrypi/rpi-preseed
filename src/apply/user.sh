# shellcheck shell=dash
# rpi-preseed applier — [user]: rename the preconfigured user + set password;
# [[users]]: create additional accounts.
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

    # An immutable image's UID 1000 account lives in its read-only /etc/passwd.
    if ! writable_dir "$(target_path /etc)"; then
        for _au_k in name password passwordless_sudo groups; do
            toml_present "user.$_au_k" && report_key "user.$_au_k" skipped "read-only filesystem"
        done
        log_warn "user: /etc is read-only, so the UID 1000 account cannot change; add accounts with [[users]]"
        return 0
    fi

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
        if is_redacted "$_au_pass"; then
            # Empty hash leaves the password set last time alone.
            report_key user.password skipped "consumed by an earlier apply"
        elif toml_bool user.password_encrypted false; then
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
        _apply_user_sudo "$_au_new" user
    fi

    if toml_present user.groups; then
        _apply_user_groups "$_au_new" user
    fi
}

# apply_users — [[users]]: create each additional account, or bring an existing
# one in line. The config wins: an existing account's password is reset to the
# configured one, with a warning. System accounts (UID below 1000) are refused.
apply_users() {
    _aus_rc=0
    for _aus_i in $(toml_indices users); do
        _apply_one_user "users.$_aus_i" || _aus_rc=1
    done
    return "$_aus_rc"
}

# _apply_one_user PREFIX — apply the [[users]] entry whose keys start PREFIX.
_apply_one_user() {
    _aou_p=$1
    _aou_name=$(toml_get "$_aou_p.name")

    _aou_hash=""
    if toml_present "$_aou_p.password"; then
        _aou_pass=$(toml_get "$_aou_p.password")
        if is_redacted "$_aou_pass"; then
            report_key "$_aou_p.password" skipped "consumed by an earlier apply"
        elif toml_bool "$_aou_p.password_encrypted" false; then
            _aou_hash="$_aou_pass"
        elif ! _aou_hash=$(hash_password "$_aou_pass"); then
            report_key "$_aou_p.password" failed "no crypt tool"
            return 1
        fi
    fi

    _aou_ids=$(user_ids "$_aou_name")
    if [ -z "$_aou_ids" ]; then
        if ! _create_user "$_aou_name"; then
            report_key "$_aou_p.name" failed "could not create"
            return 1
        fi
        report_key "$_aou_p.name" applied "created"
    elif [ "${_aou_ids%%:*}" -lt 1000 ]; then
        log_error "users: refusing to manage system account '$_aou_name'"
        report_key "$_aou_p.name" failed "system account"
        return 1
    else
        report_key "$_aou_p.name" applied "exists"
        [ -n "$_aou_hash" ] && \
            log_warn "users: account '$_aou_name' already exists; resetting its password to the configured one"
    fi

    if [ -n "$_aou_hash" ]; then
        if _set_user_hash "$_aou_name" "$_aou_hash"; then
            report_key "$_aou_p.password" applied
        else
            report_key "$_aou_p.password" failed; return 1
        fi
    fi

    if toml_bool "$_aou_p.passwordless_sudo" false; then
        _apply_user_sudo "$_aou_name" "$_aou_p"
    fi
    if toml_present "$_aou_p.groups"; then
        _apply_user_groups "$_aou_name" "$_aou_p" || return 1
    fi
    if toml_present "$_aou_p.authorized_keys"; then
        toml_array "$_aou_p.authorized_keys" | ssh_add_keys "$_aou_name"
        report_key "$_aou_p.authorized_keys" applied
    fi
    return 0
}

# _create_user NAME — add a login account with a home from /etc/skel. It starts
# locked; a configured password or SSH key is what lets anyone in.
_create_user() {
    if helpers_live; then
        useradd -m -s /bin/bash "$1"
    else
        _create_user_fallback "$1"
    fi
}

# _create_user_fallback NAME — sandbox-only passwd/group/shadow edit. Takes the
# next free UID from 1000 and, as useradd does, a group of the same name and ID.
_create_user_fallback() {
    _cuf_passwd=$(target_path /etc/passwd)
    _cuf_group=$(target_path /etc/group)
    _cuf_shadow=$(target_path /etc/shadow)
    [ -f "$_cuf_passwd" ] || return 1
    _cuf_id=$(cat "$_cuf_passwd" "$_cuf_group" 2>/dev/null | awk -F: '
        $3>=1000 && $3<60000 && $3>=n {n=$3+1} END{print (n ? n : 1000)}')
    printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$1" "$_cuf_id" "$_cuf_id" "$1" \
        2>/dev/null >>"$_cuf_passwd" || return 1
    printf '%s:x:%s:\n' "$1" "$_cuf_id" 2>/dev/null >>"$_cuf_group" || return 1
    if [ -f "$_cuf_shadow" ]; then
        printf '%s:!:%s:0:99999:7:::\n' "$1" "$(( $(date +%s) / 86400 ))" \
            2>/dev/null >>"$_cuf_shadow" || return 1
    fi
    _cuf_home=$(target_path "/home/$1")
    ensure_dir "$_cuf_home" 700 || return 1
    [ -d "$(target_path /etc/skel)" ] && cp -a "$(target_path /etc/skel)/." "$_cuf_home/"
    chown -R "$_cuf_id:$_cuf_id" "$_cuf_home" 2>/dev/null || true
}

# _set_user_hash NAME HASH — set NAME's crypt(3) hash. chpasswd -e keeps it off
# the command line.
_set_user_hash() {
    if helpers_live; then
        printf '%s:%s\n' "$1" "$2" | chpasswd -e
    else
        _suh_shadow=$(target_path /etc/shadow)
        [ -f "$_suh_shadow" ] || return 1
        awk -F: -v u="$1" -v h="$2" 'BEGIN{OFS=":"} $1==u {$2=h} {print}' \
            "$_suh_shadow" >"$_suh_shadow.tmp" && mv -f "$_suh_shadow.tmp" "$_suh_shadow"
    fi
}

# _apply_user_sudo USER PREFIX — a sudoers drop-in letting USER skip the password.
_apply_user_sudo() {
    _ausu_f=$(target_path "/etc/sudoers.d/010_${1}-nopasswd")
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$1" | atomic_write "$_ausu_f" 440
    report_key "$2.passwordless_sudo" applied
}

# _apply_user_groups USER PREFIX — add USER to each group in PREFIX.groups.
#
# This is what lets Imager (or a hand-written config) grant the operator real
# privileges, most importantly membership of the 'sudo' group so the account can
# run `sudo`. Adding to a group is append-only: primary group and existing
# memberships are preserved. A group that does not exist on this image is warned
# and skipped rather than failing the whole apply, so a typo or an
# image-dependent group (e.g. gpio) never aborts first boot.
_apply_user_groups() {
    _aug_user="$1"; _aug_p="$2"
    _aug_added=""; _aug_missing=""; _aug_failed=""
    for _aug_g in $(toml_array "$_aug_p.groups"); do
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
    [ -n "$_aug_added" ]   && report_key "$_aug_p.groups" applied "$_aug_added"
    [ -n "$_aug_missing" ] && report_key "$_aug_p.groups" skipped "no such group: $_aug_missing"
    if [ -n "$_aug_failed" ]; then
        report_key "$_aug_p.groups" failed "$_aug_failed"
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
