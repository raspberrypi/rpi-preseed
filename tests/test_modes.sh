# shellcheck shell=dash
# Permissions on everything an apply writes.
#
# mktemp creates 0600 whatever the umask is and mv carries that onto the
# destination, so atomic_write used to tighten every file it replaced. A
# rewritten /etc/default/keyboard at 600 is unreadable by the desktop session,
# which is what stopped wayvnc starting (issue #5), and every assertion around
# it passed: they all asked what the file said, never who could read it.

t_modes() {
    _tm_d=$(mktemp -d)

    printf 'old\n' >"$_tm_d/packaged"
    chmod 644 "$_tm_d/packaged"
    printf 'new\n' | atomic_write "$_tm_d/packaged"
    assert_eq "atomic_write keeps a replaced file's mode" \
        "$(stat -c %a "$_tm_d/packaged")" "644"
    assert_eq "atomic_write still replaces the contents" \
        "$(cat "$_tm_d/packaged")" "new"

    printf 'old\n' >"$_tm_d/odd"
    chmod 640 "$_tm_d/odd"
    printf 'new\n' | atomic_write "$_tm_d/odd"
    assert_eq "atomic_write keeps a mode it would not have chosen" \
        "$(stat -c %a "$_tm_d/odd")" "640"

    printf 'x\n' | atomic_write "$_tm_d/fresh"
    assert_eq "a new file lands readable, not at mktemp's 600" \
        "$(stat -c %a "$_tm_d/fresh")" "644"

    printf 'x\n' | atomic_write "$_tm_d/secret" 600
    assert_eq "an explicit mode is applied to a new file" \
        "$(stat -c %a "$_tm_d/secret")" "600"

    # A secret rewritten over a lax file must not inherit the laxity, and gets
    # its mode before the rename rather than from a chmod racing readers after.
    printf 'old\n' >"$_tm_d/leaky"
    chmod 644 "$_tm_d/leaky"
    printf 'new\n' | atomic_write "$_tm_d/leaky" 600
    assert_eq "an explicit mode overrides what was there" \
        "$(stat -c %a "$_tm_d/leaky")" "600"

    rm -rf "$_tm_d"
}

# t_written_modes — mode of every file a full base apply produces.
#
# The table pins what each file is meant to be. The sweep after it is the part
# that covers an applier nobody has added a row for: no file may be writable by
# group or other, and nothing under /etc may be root-only-readable unless it is
# a secret that has to be. Add a row for a new file; add to the sweep's secret
# list only when the file genuinely must not be world-readable.
t_written_modes() {
    _twm_root=$(mktemp -d)
    mkdir -p "$_twm_root/etc/default" "$_twm_root/etc/ssh" \
        "$_twm_root/boot/firmware" "$_twm_root/home/alice"
    echo "alice:x:1000:1000:,,,:/home/alice:/bin/bash" >"$_twm_root/etc/passwd"
    printf '127.0.0.1\tlocalhost\n' >"$_twm_root/etc/hosts"
    printf 'XKBMODEL="pc105"\nXKBLAYOUT="us"\n' >"$_twm_root/etc/default/keyboard"
    printf '# en_GB.UTF-8 UTF-8\n' >"$_twm_root/etc/locale.gen"
    printf 'console=serial0,115200\n' >"$_twm_root/boot/firmware/cmdline.txt"
    chmod 644 "$_twm_root/etc/hosts" "$_twm_root/etc/locale.gen" \
        "$_twm_root/boot/firmware/cmdline.txt"
    # A machine an older version already broke: the applier owns this file
    # outright, so re-applying has to repair the mode rather than preserve it.
    # /etc/hosts above is the other half of the pair -- an applier only edits
    # that one, so whatever mode it is found at is kept.
    chmod 600 "$_twm_root/etc/default/keyboard"
    cat >"$_twm_root/boot/firmware/rpi-preseed.toml" <<'CFG'
config_version = "1.0"
[system]
hostname = "mypi"
[user]
name = "alice"
passwordless_sudo = true
[locale]
timezone = "Europe/London"
keymap = "gb"
keymap_variant = "dvorak"
locales = ["en_GB.UTF-8"]
[ssh]
enabled = true
authorized_keys = ["ssh-ed25519 AAAAKEY1 a@b"]
[wlan]
ssid = "testnet"
password = "testpassword"
[ethernet]
method = "dhcp"
[time]
ntp = ["ntp.example.org"]
[connect]
enabled = true
mode = "token"
token = "tok-abc-123"
[boot]
cmdline = ["quiet"]
config_txt = ["dtparam=audio=on"]
CFG
    # 644 because the apply redacts the secrets in this file in place, keeping
    # the mode it was given, so it lands in the sweep below like anything else.
    chmod 644 "$_twm_root/boot/firmware/rpi-preseed.toml"

    # The sweep walks whatever is newer than this marker, so it covers what the
    # apply wrote and not the fixtures set up above.
    touch "$_twm_root/.before-apply"

    # umask 002 on the way in: an apply's permissions are its own business, not
    # an inheritance from whichever shell or unit happened to invoke it.
    ( umask 002
      env -u RPI_PRESEED_STATE_DIR -u RPI_PRESEED_BOOT_DIR \
        RPI_PRESEED_ROOT="$_twm_root" \
        RPI_PRESEED_CONFIG="$_twm_root/boot/firmware/rpi-preseed.toml" \
        sh "$REPO/src/rpi-preseed" apply --phase base ) >/dev/null 2>&1

    while IFS='|' read -r _twm_p _twm_m; do
        if [ ! -e "$_twm_root/$_twm_p" ]; then
            no "written file present: $_twm_p"
            continue
        fi
        assert_eq "written file mode: $_twm_p" \
            "$(stat -c %a "$_twm_root/$_twm_p" 2>/dev/null)" "$_twm_m"
    done <<'ROWS'
etc/default/keyboard|644
etc/default/locale|644
etc/locale.gen|644
etc/timezone|644
etc/hostname|644
etc/hosts|644
etc/ssh/sshd_config.d/rpi-preseed.conf|644
etc/systemd/timesyncd.conf.d/10-rpi-preseed.conf|644
etc/sudoers.d/010_alice-nopasswd|440
etc/NetworkManager/system-connections/preconfigured.nmconnection|600
etc/NetworkManager/system-connections/preconfigured-ethernet.nmconnection|600
boot/firmware/cmdline.txt|644
boot/firmware/config.txt|644
boot/firmware/ssh|644
boot/firmware/rpi-preseed/status.txt|644
var/lib/rpi-preseed/applied|644
var/lib/rpi-preseed/report.json|644
var/lib/rpi-preseed/redaction-salt|600
var/lib/rpi-preseed/log/base.log|644
home/alice/.config/labwc/environment|644
home/alice/.ssh/authorized_keys|600
home/alice/.config/com.raspberrypi.connect/auth.key|600
ROWS

    _twm_loose=$(find "$_twm_root" -type f -newer "$_twm_root/.before-apply" \
        -perm /022 -printf '%P ' 2>/dev/null)
    assert_eq "nothing written is group- or world-writable" "$_twm_loose" ""

    # Anything the rest of the system reads as a non-root user, which on a
    # desktop image includes the compositor reading the keymap.
    _twm_shut=$(find "$_twm_root/etc" -type f -newer "$_twm_root/.before-apply" \
        ! -perm -004 -printf '%P\n' 2>/dev/null \
        | grep -vE '^(sudoers\.d/|NetworkManager/system-connections/)' \
        | tr '\n' ' ' | sed 's/ *$//')
    assert_eq "nothing under /etc is left root-only-readable" "$_twm_shut" ""

    rm -rf "$_twm_root"
}
