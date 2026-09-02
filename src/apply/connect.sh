# shellcheck shell=dash
# rpi-preseed applier — [connect]: Raspberry Pi Connect enrolment.
#
# The daemon prefers a hardware device-identity and falls back to auth.key, so we
# only ever need to (optionally) write the token; device-identity needs no flag.

apply_connect() {
    toml_present connect.enabled || return 0
    toml_bool connect.enabled false || { report_key connect.enabled skipped "disabled"; return 0; }

    _ac_mode=$(toml_get_default connect.mode device-identity)
    _ac_user=$(toml_get_default user.name "$(first_user)")
    [ -n "$_ac_user" ] || _ac_user=pi

    # Resolved from the target's passwd rather than assumed, since an image can
    # put a home anywhere; /home/<user> is the fallback when passwd has nothing.
    _ac_home=$(user_home "$_ac_user")
    [ -n "$_ac_home" ] || _ac_home="/home/$_ac_user"
    _ac_home=$(target_path "$_ac_home")

    if [ "$_ac_mode" = token ]; then
        _ac_token=$(toml_get connect.token)
        _ac_dir="$_ac_home/.config/com.raspberrypi.connect"
        ensure_dir "$_ac_dir" 700
        if printf '%s' "$_ac_token" | atomic_write "$_ac_dir/auth.key"; then
            chmod 600 "$_ac_dir/auth.key" 2>/dev/null || true
            # The daemon reads this as the user, so the user has to own it.
            # .config is included because ensure_dir will have created that too
            # on an account that has never logged in, and a root-owned .config
            # would take more than Connect down with it.
            own_user_path "$_ac_user" "$_ac_home/.config" "$_ac_dir" \
                "$_ac_dir/auth.key"
            report_key connect.token applied
        else
            # Reported rather than swallowed: an unwritable token is the whole
            # of what token mode was asked to do.
            report_key connect.token failed "could not write $_ac_dir/auth.key"
        fi
    fi

    _ac_enable_user_units "$_ac_user" "$_ac_home"

    # Record whether the board already carries a firmware device-unique
    # identity. Device-identity enrolment relies on this hardware key, so
    # capturing its presence makes the report actionable ("enabled but no
    # device key" explains why unattended enrolment did nothing).
    _report_connect_device_identity

    # rpi-connect's units are systemd *user* units, so `rpi-connect on` as root
    # turns Connect on for root -- an account that holds no token and is not the
    # one being enrolled. Drive it as the target user instead. Best effort on top
    # of the static enablement above, which is what makes this survive a boot
    # where no user manager is running yet.
    if helpers_live && have rpi-connect && have runuser; then
        runuser -u "$_ac_user" -- rpi-connect on >/dev/null 2>&1 || true
    fi
    report_key connect.enabled applied "$_ac_mode"
}

# _report_connect_device_identity — report presence of the firmware
# device-unique key (used by Raspberry Pi Connect device-identity enrolment),
# probed with rpi-fw-crypto. Diagnostic only: never fails the apply.
#
# The device-unique key lives at key-id 1 and is flagged DEVICE in
# `rpi-fw-crypto get-key-status`. We treat that flag as authoritative for "a
# device identity is present", with a pubkey read-back as a fallback probe in
# case the status text ever changes.
_report_connect_device_identity() {
    if ! helpers_live || ! have rpi-fw-crypto; then
        report_key connect.device_identity unknown "rpi-fw-crypto unavailable"
        return 0
    fi

    _rcdi_status=$(rpi-fw-crypto get-key-status 1 2>/dev/null || true)
    case "$_rcdi_status" in
        *DEVICE*)
            report_key connect.device_identity present "fw-crypto key-id 1 (DEVICE)"
            return 0
            ;;
    esac

    if rpi-fw-crypto pubkey --key-id 1 >/dev/null 2>&1; then
        report_key connect.device_identity present "fw-crypto key-id 1 (pubkey)"
    else
        report_key connect.device_identity absent "no fw-crypto device key"
    fi
}

# _ac_enable_user_units USER HOME — statically enable Connect's systemd *user*
# units for USER, and let that user's manager start without a login.
#
# `rpi-connect on` needs a running user manager, and a first boot has none: the
# account has never signed in and lingering is off by default. Two file-level
# steps survive that, and are what Imager's own firstrun script does before it
# tries to start anything: symlink the units into the account's
# .config/systemd/user wants directories, which its manager reads whenever it
# next starts, and enable lingering so systemd-logind starts that manager at
# boot. Both are plain files, so they apply to a mounted image as readily as to
# a live system.
_ac_enable_user_units() {
    _aeu_user=$1
    _aeu_base="$2/.config/systemd/user"

    ensure_dir "$_aeu_base/default.target.wants" 700 || return 0
    ensure_dir "$_aeu_base/paths.target.wants" 700 || return 0

    _aeu_linked=0
    _ac_link_unit "$_aeu_base/default.target.wants" rpi-connect.service &&
        _aeu_linked=$((_aeu_linked + 1))
    _ac_link_unit "$_aeu_base/default.target.wants" rpi-connect-wayvnc.service &&
        _aeu_linked=$((_aeu_linked + 1))
    _ac_link_unit "$_aeu_base/paths.target.wants" rpi-connect-signin.path &&
        _aeu_linked=$((_aeu_linked + 1))

    if [ "$_aeu_linked" -eq 0 ]; then
        # Nothing to enable: this image does not ship Connect. Not a failure --
        # the token is still in place for whenever it is installed.
        report_key connect.units skipped "rpi-connect units not present"
        return 0
    fi

    own_user_path "$_aeu_user" \
        "$2/.config" "$2/.config/systemd" "$_aeu_base" \
        "$_aeu_base/default.target.wants" \
        "$_aeu_base/default.target.wants/rpi-connect.service" \
        "$_aeu_base/default.target.wants/rpi-connect-wayvnc.service" \
        "$_aeu_base/paths.target.wants" \
        "$_aeu_base/paths.target.wants/rpi-connect-signin.path"

    _aeu_linger=$(target_path /var/lib/systemd/linger)
    ensure_dir "$_aeu_linger" 755 && : | atomic_write "$_aeu_linger/$_aeu_user"

    report_key connect.units applied "$_aeu_linked linked, lingering enabled"
}

# _ac_link_unit WANTSDIR UNIT — link WANTSDIR/UNIT to the shipped unit file.
#
# The link has to name the on-device path, while the check for it and the link
# itself are made under any target root, so the two paths differ by design.
# Fails when the image does not ship the unit, leaving nothing behind.
_ac_link_unit() {
    for _alu_dir in /usr/lib/systemd/user /lib/systemd/user; do
        if [ -f "$(target_path "$_alu_dir/$2")" ]; then
            ln -sf "$_alu_dir/$2" "$1/$2" 2>/dev/null || return 1
            return 0
        fi
    done
    return 1
}
