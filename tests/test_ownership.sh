# shellcheck shell=dash
# Ownership of files written into a user's home. Everything an applier writes is
# created by root, and a root-owned file at mode 600 cannot be read by the
# account it was written for -- which is the account a systemd user unit runs as.
# The chown itself needs privilege, so these cover the resolution it depends on.

t_ownership() {
    # Live branch: resolved through getent for the running user.
    _to_me=$(id -un 2>/dev/null)
    if [ -n "$_to_me" ]; then
        assert_eq "user_ids resolves the running user" \
            "$(RPI_PRESEED_ROOT='' user_ids "$_to_me")" "$(id -u):$(id -g)"
    fi

    # Target branch: resolved through the image's own passwd, so applying to a
    # mounted image cannot inherit the host's idea of who a name belongs to.
    _to_root=$(mktemp -d)
    mkdir -p "$_to_root/etc"
    printf 'root:x:0:0:root:/root:/bin/sh\nalice:x:1000:1000::/home/alice:/bin/sh\n' \
        >"$_to_root/etc/passwd"
    assert_eq "user_ids reads the target passwd, not the host's" \
        "$(RPI_PRESEED_ROOT=$_to_root user_ids alice)" "1000:1000"
    assert_eq "user_ids is empty for a user the target does not have" \
        "$(RPI_PRESEED_ROOT=$_to_root user_ids nobodyhere)" ""
    assert_eq "user_home reads the target passwd" \
        "$(RPI_PRESEED_ROOT=$_to_root user_home alice)" "/home/alice"
    assert_eq "user_home is empty for a user the target does not have" \
        "$(RPI_PRESEED_ROOT=$_to_root user_home nobodyhere)" ""

    # Never fails an applier, whatever it is handed.
    assert_ok "own_user_path tolerates an unknown user" \
        "( RPI_PRESEED_ROOT=$_to_root; own_user_path nobodyhere $_to_root/etc/passwd )"
    assert_ok "own_user_path tolerates an absent path" \
        "( RPI_PRESEED_ROOT=$_to_root; own_user_path alice $_to_root/nonexistent )"
    assert_ok "own_user_path tolerates a chown it cannot make" \
        "( RPI_PRESEED_ROOT=$_to_root; own_user_path alice $_to_root/etc/passwd )"
    rm -rf "$_to_root"
}

# t_home_artefacts — every file an applier puts inside a user's home, asserted
# by location and mode in one table.
#
# This is the shape of check that was missing when a root-owned auth.key
# shipped: the assertions around it were all "does the file hold the right
# bytes", and a file the account cannot read passes every one of those. Mode is
# assertable unprivileged; ownership is not, since the sandbox cannot chown at
# all, so the owner is checked only when the suite runs as root and is covered
# for real by the qemu scenario. Add a row whenever an applier starts writing
# somewhere new under a home.
t_home_artefacts() {
    _tha_root=$(mktemp -d)
    mkdir -p "$_tha_root/etc" "$_tha_root/boot/firmware" "$_tha_root/home/alice" \
        "$_tha_root/usr/lib/systemd/user"
    echo "alice:x:1000:1000:,,,:/home/alice:/bin/bash" >"$_tha_root/etc/passwd"
    for _tha_u in rpi-connect.service rpi-connect-wayvnc.service rpi-connect-signin.path; do
        : >"$_tha_root/usr/lib/systemd/user/$_tha_u"
    done
    cat >"$_tha_root/boot/firmware/rpi-preseed.toml" <<'CFG'
config_version = "1.0"
[ssh]
enabled = true
authorized_keys = ["ssh-ed25519 AAAAKEY1 a@b"]
[connect]
enabled = true
mode = "token"
token = "tok-abc-123"
CFG
    ( env -u RPI_PRESEED_STATE_DIR -u RPI_PRESEED_BOOT_DIR \
        RPI_PRESEED_ROOT="$_tha_root" \
        RPI_PRESEED_CONFIG="$_tha_root/boot/firmware/rpi-preseed.toml" \
        sh "$REPO/src/rpi-preseed" apply --phase base ) >/dev/null 2>&1

    # Rows are path|mode, fed by redirection rather than a pipe: a piped `while`
    # runs in a subshell, where ok/no would bump counters the runner never sees
    # and a failure would print FAIL while the suite still exited 0. Directories
    # carry a mode because a 700 the account cannot enter is as bad as a 600 it
    # cannot read.
    while IFS='|' read -r _tha_p _tha_m; do
        if [ ! -e "$_tha_root/$_tha_p" ]; then
            no "home artefact present: $_tha_p"
            continue
        fi
        ok "home artefact present: $_tha_p"
        assert_eq "home artefact mode: $_tha_p" \
            "$(stat -c %a "$_tha_root/$_tha_p" 2>/dev/null)" "$_tha_m"
    done <<'ROWS'
home/alice/.ssh|700
home/alice/.ssh/authorized_keys|600
home/alice/.config/com.raspberrypi.connect|700
home/alice/.config/com.raspberrypi.connect/auth.key|600
home/alice/.config/systemd/user/default.target.wants|700
home/alice/.config/systemd/user/paths.target.wants|700
ROWS

    # Ownership for real, when the suite is privileged enough to have set it.
    if [ "$(id -u)" = 0 ]; then
        for _tha_p in home/alice/.ssh/authorized_keys \
                      home/alice/.config/com.raspberrypi.connect/auth.key \
                      home/alice/.config/systemd/user; do
            assert_eq "home artefact owned by the account: $_tha_p" \
                "$(stat -c %u:%g "$_tha_root/$_tha_p" 2>/dev/null)" "1000:1000"
        done
    else
        ok "home artefact ownership checked by the qemu scenario (needs root here)"
    fi
    rm -rf "$_tha_root"
}
