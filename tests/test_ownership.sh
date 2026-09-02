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
