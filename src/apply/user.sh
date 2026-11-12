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

    # An immutable image's UID 1000 account lives in its read-only /etc/passwd
    # and cannot be renamed, so the named account is made in userdb instead.
    # This is what lets an unchanged Imager configure such an image.
    if ! _accounts_writable; then
        if toml_present user.name && _select_users_backend user.name && \
           [ "$USERS_BACKEND" = userdb ]; then
            _apply_one_user user || return 1
            # shellcheck disable=SC2034  # read by apply/ssh.sh
            PRIMARY_USER=$(toml_get user.name)
            return 0
        fi
        for _au_k in name password passwordless_sudo groups; do
            toml_present "user.$_au_k" && report_key "user.$_au_k" skipped "$ACCOUNTS_WHY"
        done
        log_warn "user: /etc/passwd is $ACCOUNTS_WHY, so the UID 1000 account cannot change"
        return 0
    fi
    USERS_BACKEND=passwd

    _au_prev=$(first_user)
    if [ -z "$_au_prev" ] && ! toml_present user.name; then
        for _au_k in password passwordless_sudo groups; do
            toml_present "user.$_au_k" && report_key "user.$_au_k" skipped "no UID 1000 account"
        done
        return 0
    fi

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

        # The image may have no UID 1000 account, or no userconf-pi.
        if [ -z "$_au_prev" ]; then
            _au_how=created
            _create_first_user "$_au_new" "$_au_hash"
        elif helpers_live && [ -x "$USERCONF" ]; then
            _au_how=userconf
            "$USERCONF" "$_au_prev" "$_au_new" "$_au_hash"
        elif helpers_live; then
            _au_how=usermod
            _rename_user_live "$_au_prev" "$_au_new" "$_au_hash"
        else
            _au_how=fallback
            _apply_user_fallback "$_au_prev" "$_au_new" "$_au_hash"
        fi
        _au_rc=$?
        if [ "$_au_rc" -ne 0 ] || [ "$(first_user)" != "$_au_new" ]; then
            log_error "user: UID 1000 is not '$_au_new' after $_au_how"
            report_key user.name failed "$_au_how"
            [ -n "$_au_hash" ] && report_key user.password failed "$_au_how"
            return 1
        fi
        report_key user.name applied "$_au_how"
        [ -n "$_au_hash" ] && report_key user.password applied "$_au_how"
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
    _aus_idx=$(toml_indices users)
    [ -n "$_aus_idx" ] || return 0
    _aus_keys=""
    for _aus_i in $_aus_idx; do _aus_keys="$_aus_keys users.$_aus_i.name"; done
    # shellcheck disable=SC2086  # one argument per entry
    _select_users_backend $_aus_keys || return 1
    [ "$USERS_BACKEND" = none ] && return 0
    _aus_rc=0
    for _aus_i in $_aus_idx; do
        _apply_one_user "users.$_aus_i" || _aus_rc=1
    done
    return "$_aus_rc"
}

# _select_users_backend KEY... — set USERS_BACKEND to passwd, userdb or none.
# An immutable image's /etc/passwd is read-only; systemd's userdb takes
# accounts as drop-in records instead, from a directory it can share. KEYs are
# reported when no account can be made.
_select_users_backend() {
    if _accounts_writable; then
        USERS_BACKEND=passwd
    elif writable_dir "$(target_path /etc/userdb)" && persists "$(target_path /etc/userdb)"; then
        USERS_BACKEND=userdb
        if ! grep -Eq '^passwd:.*[[:space:]]systemd' "$(target_path /etc/nsswitch.conf)" 2>/dev/null; then
            log_error "users: /etc/passwd is read-only and NSS does not read userdb; install libnss-systemd"
            for _sub_k in "$@"; do report_key "$_sub_k" failed "libnss-systemd missing"; done
            return 1
        fi
    else
        USERS_BACKEND=none
        log_warn "users: neither /etc/passwd nor /etc/userdb would keep an account; none added"
        for _sub_k in "$@"; do report_key "$_sub_k" skipped "$ACCOUNTS_WHY"; done
    fi
    return 0
}

# _accounts_writable — can /etc/passwd and its siblings be changed for good?
# If not, ACCOUNTS_WHY says why, as a report detail.
_accounts_writable() {
    ACCOUNTS_WHY="read-only filesystem"
    writable_dir "$(target_path /etc)" || return 1
    ACCOUNTS_WHY="not persisted"
    for _acw_f in passwd shadow group gshadow; do
        persists "$(target_path "/etc/$_acw_f")" || return 1
    done
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
    if [ "$USERS_BACKEND" = userdb ] && [ -n "$_aou_ids" ] && \
       [ ! -f "$(target_path "/etc/userdb/$_aou_name.user")" ]; then
        log_warn "users: '$_aou_name' is in the image's read-only /etc/passwd; leaving it alone"
        report_key "$_aou_p.name" skipped "read-only filesystem"
        return 0
    fi
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
    if [ "$USERS_BACKEND" = userdb ]; then
        _create_userdb_user "$1"
    elif helpers_live; then
        useradd -m -s /bin/bash "$1"
    else
        _create_user_fallback "$1"
    fi
}

# _create_userdb_user NAME — a userdb account and its own group, as drop-in
# records nss-systemd reads directly. IDs count down from 59999, away from the
# image's own accounts, which count up from 1000.
_create_userdb_user() {
    _cuu_dir=$(target_path /etc/userdb)
    _cuu_id=$({
        cut -d: -f3 "$(target_path /etc/passwd)" "$(target_path /etc/group)" 2>/dev/null
        cat "$_cuu_dir"/*.user "$_cuu_dir"/*.group 2>/dev/null | grep -o '"[ug]id":[0-9]*' | cut -d: -f2
    } | sort -n | awk 'BEGIN{n=59999} {u[$1]=1} END{while (u[n]) n--; print n}')
    printf '{"userName":"%s","uid":%s,"gid":%s,"homeDirectory":"/home/%s","shell":"/bin/bash","disposition":"regular"}\n' \
        "$1" "$_cuu_id" "$_cuu_id" "$1" | atomic_write "$_cuu_dir/$1.user" 644 || return 1
    printf '{"groupName":"%s","gid":%s,"disposition":"regular"}\n' "$1" "$_cuu_id" \
        | atomic_write "$_cuu_dir/$1.group" 644 || return 1
    # Lookups by number go through these links.
    ln -sfn "$1.user" "$_cuu_dir/$_cuu_id.user" && ln -sfn "$1.group" "$_cuu_dir/$_cuu_id.group" || return 1
    _cuu_home=$(target_path "/home/$1")
    ensure_dir "$_cuu_home" 700 || return 1
    [ -d "$(target_path /etc/skel)" ] && cp -a "$(target_path /etc/skel)/." "$_cuu_home/"
    chown -R "$_cuu_id:$_cuu_id" "$_cuu_home" 2>/dev/null || true
}

# _json_escape TEXT — TEXT as the inside of a JSON string.
_json_escape() {
    printf '%s\n' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
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
    if [ "$USERS_BACKEND" = userdb ]; then
        _json_escape "$2" | awk '{printf "{\"privileged\":{\"hashedPassword\":[\"%s\"]}}\n", $0}' \
            | atomic_write "$(target_path "/etc/userdb/$1.user-privileged")" 600
    elif helpers_live; then
        printf '%s:%s\n' "$1" "$2" | chpasswd -e
    else
        _suh_shadow=$(target_path /etc/shadow)
        [ -f "$_suh_shadow" ] || return 1
        awk -F: -v u="$1" -v h="$2" 'BEGIN{OFS=":"} $1==u {$2=h} {print}' \
            "$_suh_shadow" >"$_suh_shadow.tmp" && mv -f "$_suh_shadow.tmp" "$_suh_shadow"
    fi
}

# Every account's NOPASSWD rule, in one file: a fixed name is one an A/B image
# can declare with EarlyPersistFile=.
SUDOERS_NOPASSWD=/etc/sudoers.d/010_rpi-preseed-nopasswd

# _apply_user_sudo USER PREFIX — let USER sudo without a password.
_apply_user_sudo() {
    _ausu_f=$(target_path "$SUDOERS_NOPASSWD")
    writable_or_skip "$2.passwordless_sudo" "$_ausu_f" || return 0
    if ! grep -q "^$1 " "$_ausu_f" 2>/dev/null; then
        { cat "$_ausu_f" 2>/dev/null; printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$1"; } \
            | atomic_write "$_ausu_f" 440 || { report_key "$2.passwordless_sudo" failed; return 1; }
    fi
    report_key "$2.passwordless_sudo" applied
}

# _create_first_user NAME HASH — make NAME the UID 1000 account.
_create_first_user() {
    if ! helpers_live; then
        _create_user_fallback "$1" || return 1
    elif getent group 1000 >/dev/null 2>&1; then
        useradd -m -u 1000 -g 1000 -s /bin/bash "$1" || return 1
    else
        useradd -m -u 1000 -U -s /bin/bash "$1" || return 1
    fi
    [ -z "$2" ] || _set_user_hash "$1" "$2"
}

# _rename_user_live PREV NEW HASH — what userconf-pi does, for an image without
# it. Its cancel-rename display-manager fix-ups come with it, so are not done.
_rename_user_live() {
    if [ "$1" != "$2" ]; then
        usermod -l "$2" "$1" || return 1
        usermod -m -d "/home/$2" "$2" || return 1
        if getent group "$1" >/dev/null 2>&1; then
            groupmod -n "$2" "$1" || return 1
        fi
        for _rul_f in /etc/subuid /etc/subgid; do
            [ -f "$_rul_f" ] && sed -i "s/^$1:/$2:/" "$_rul_f"
        done
        for _rul_f in /etc/sudoers.d/010_pi-nopasswd "$SUDOERS_NOPASSWD"; do
            [ -f "$_rul_f" ] && sed -i "s/^$1 /$2 /" "$_rul_f"
        done
    fi
    usermod -s /bin/bash "$2" || return 1
    [ -z "$3" ] || printf '%s:%s\n' "$2" "$3" | chpasswd -e
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
    if [ "${USERS_BACKEND:-}" = userdb ]; then
        # Must not be empty: systemd reads an empty drop-in as a mask.
        echo | atomic_write "$(target_path "/etc/userdb/$_autg_u:$_autg_g.membership")" 644
    elif helpers_live; then
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
    if [ "$_auf_prev" != "$_auf_new" ]; then
        for _auf_f in passwd shadow group gshadow; do
            _auf_p=$(target_path "/etc/$_auf_f")
            [ -f "$_auf_p" ] || continue
            sed -e "s/^$_auf_prev:/$_auf_new:/" -e "/^$_auf_new:/s|:/home/$_auf_prev:|:/home/$_auf_new:|" \
                "$_auf_p" | atomic_write "$_auf_p" || return 1
        done
        _auf_h=$(target_path /home)
        [ -d "$_auf_h/$_auf_prev" ] && [ ! -e "$_auf_h/$_auf_new" ] && mv "$_auf_h/$_auf_prev" "$_auf_h/$_auf_new"
    fi
    [ -z "$_auf_hash" ] || _set_user_hash "$_auf_new" "$_auf_hash"
}
