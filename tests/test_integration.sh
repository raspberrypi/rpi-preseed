# shellcheck shell=dash
# End-to-end tests driving the CLI against a sandbox rootfs (no root needed).

t_integration() {
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware" "$ROOT/home/pi"
    echo "pi:x:1000:1000:,,,:/home/pi:/bin/bash" >"$ROOT/etc/passwd"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\traspberrypi\n' >"$ROOT/etc/hosts"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[system]
hostname = "mypi"
[ssh]
enabled = true
authorized_keys = ["ssh-ed25519 AAAA test@host"]
[locale]
keymap = "gb"
keymap_variant = "dvorak"
[interfaces]
usb_gadget = true
[boot]
config_txt = ["dtparam=audio=on"]
EOF

    rpp() {
        env -u RPI_PRESEED_STATE_DIR -u RPI_PRESEED_BOOT_DIR \
            RPI_PRESEED_ROOT="$ROOT" RPI_PRESEED_CONFIG="$CFG" \
            sh "$RPI_PRESEED_SRCDIR/rpi-preseed" "$@"
    }

    # --- Base apply (fallback path) ---
    rpp apply --phase base >/dev/null 2>&1
    assert_eq "hostname applied" "$(cat "$ROOT/etc/hostname" 2>/dev/null)" "mypi"
    assert_contains "keyboard layout" "$(cat "$ROOT/etc/default/keyboard" 2>/dev/null)" 'XKBLAYOUT="gb"'
    assert_contains "keyboard variant (beyond Imager)" "$(cat "$ROOT/etc/default/keyboard" 2>/dev/null)" 'XKBVARIANT="dvorak"'
    assert_contains "config.txt appended" "$(cat "$ROOT/boot/firmware/config.txt" 2>/dev/null)" "dtparam=audio=on"
    assert_file "applied stamp written" "$ROOT/var/lib/rpi-preseed/applied"
    assert_file "report.json written" "$ROOT/var/lib/rpi-preseed/report.json"
    assert_file "breadcrumb written" "$ROOT/boot/firmware/rpi-preseed/status.txt"
    # usb_gadget must not be faked with a bare dwc2 overlay; it needs rpi-usb-gadget.
    assert_ncontains "usb_gadget not faked via dwc2 overlay" "$(cat "$ROOT/boot/firmware/config.txt" 2>/dev/null)" "dtoverlay=dwc2"
    assert_contains "usb_gadget reports needing rpi-usb-gadget" "$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)" "requires rpi-usb-gadget"

    # --- Run-once: second (non-force) apply is skipped ---
    echo "SENTINEL" >"$ROOT/etc/hostname"
    rpp apply-base >/dev/null 2>&1
    assert_eq "run-once skips re-apply" "$(cat "$ROOT/etc/hostname")" "SENTINEL"

    # --- Changed config is NOT auto-applied ---
    sed -i 's/hostname = "mypi"/hostname = "newpi"/' "$CFG"
    _ti_err=$(rpp apply-base 2>&1 >/dev/null)
    assert_eq "changed config not auto-applied" "$(cat "$ROOT/etc/hostname")" "SENTINEL"
    assert_contains "changed config logs hint" "$_ti_err" "config changed"

    # --- Explicit re-apply picks up the change ---
    rpp apply --phase base >/dev/null 2>&1
    assert_eq "explicit apply re-applies" "$(cat "$ROOT/etc/hostname")" "newpi"

    # --- Runcmd late: output separated from the main log ---
    # Marker is produced by decoding base64 so it does NOT appear in the command
    # text itself (which is legitimately logged), only in the command's output.
    _ti_b64=$(printf 'OUTPUT_MARKER' | base64)
    cat >"$CFG" <<EOF
config_version = "1.0"
[system]
hostname = "newpi"
[runcmd]
late = ["echo $_ti_b64 | base64 -d"]
EOF
    rpp apply --phase late >/dev/null 2>&1
    assert_file "late stamp written" "$ROOT/var/lib/rpi-preseed/runcmd-done"
    assert_contains "runcmd output captured to .out" "$(cat "$ROOT/var/lib/rpi-preseed/log/runcmd-late.out" 2>/dev/null)" "OUTPUT_MARKER"
    assert_ncontains "runcmd output NOT in main log" "$(cat "$ROOT/var/lib/rpi-preseed/log/runcmd-late.log" 2>/dev/null)" "OUTPUT_MARKER"

    # --- Runcmd late: a command containing [ ] runs, and so do the ones after it
    # (#4: the ']' used to close the array early, dropping later elements).
    cat >"$CFG" <<EOF
config_version = "1.0"
[system]
hostname = "newpi"
[runcmd]
late = [
  "echo FIRST_CMD",
  "sh -c 'if [ -d / ]; then echo BRACKET_CMD; fi'",
  "echo AFTER_BRACKET",
]
EOF
    rm -f "$ROOT/var/lib/rpi-preseed/log/runcmd-late.out"
    rpp apply --phase late >/dev/null 2>&1
    _ti_out=$(cat "$ROOT/var/lib/rpi-preseed/log/runcmd-late.out" 2>/dev/null)
    assert_contains "bracketed runcmd executes" "$_ti_out" "BRACKET_CMD"
    assert_contains "runcmd after a bracketed one executes" "$_ti_out" "AFTER_BRACKET"

    # --- collect-logs excludes runcmd output by default ---
    cat >"$CFG" <<EOF
config_version = "1.0"
[system]
hostname = "newpi"
[runcmd]
late = ["echo $_ti_b64 | base64 -d"]
EOF
    rpp apply --phase late >/dev/null 2>&1
    _ti_bundle=$(rpp collect-logs 2>/dev/null)
    assert_ncontains "default bundle excludes runcmd .out" "$(tar tzf "$_ti_bundle" 2>/dev/null)" "runcmd-late.out"
    _ti_bundle2=$(rpp collect-logs --include-runcmd-output 2>/dev/null)
    assert_contains "opt-in bundle includes runcmd .out" "$(tar tzf "$_ti_bundle2" 2>/dev/null)" "runcmd-late.out"

    rm -rf "$ROOT"

    # --- Secret redaction in config + report (separate sandbox) ---
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware" "$ROOT/home/pi"
    echo "pi:x:1000:1000:,,,:/home/pi:/bin/bash" >"$ROOT/etc/passwd"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[system]
hostname = "reddacthost"
[wlan]
ssid = "RedactNet"
password = "SUPERSECRETPSK"
key_mgmt = "sae"
EOF
    rpp apply --phase base >/dev/null 2>&1
    assert_ncontains "secret removed from config on success" "$(cat "$CFG")" "SUPERSECRETPSK"
    assert_contains "config secret replaced with marker" "$(cat "$CFG")" "<redacted by rpi-preseed>"
    assert_ncontains "secret absent from report.json" "$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)" "SUPERSECRETPSK"
    assert_ncontains "ssid pii absent from breadcrumb" "$(cat "$ROOT/boot/firmware/rpi-preseed/status.txt" 2>/dev/null)" "RedactNet"
    assert_contains "wlan honours WPA3 sae key-mgmt" "$(cat "$ROOT/etc/NetworkManager/system-connections/preconfigured.nmconnection" 2>/dev/null)" "key-mgmt=sae"

    # --- The redacted file is what was stamped: the next boot is quiet ---
    _ti_err=$(rpp apply-base 2>&1 >/dev/null)
    assert_ncontains "redacted config not reported as changed" "$_ti_err" "config changed"

    # --- A forced re-apply keeps the consumed secrets ---
    rpp apply --phase base >/dev/null 2>&1
    _ti_nm=$(cat "$ROOT/etc/NetworkManager/system-connections/preconfigured.nmconnection" 2>/dev/null)
    assert_contains "re-apply keeps the consumed psk" "$_ti_nm" "psk=SUPERSECRETPSK"
    assert_ncontains "re-apply does not write the marker as psk" "$_ti_nm" "redacted"
    rm -rf "$ROOT"

    # --- A consumed account password is not re-applied (separate sandbox) ---
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware" "$ROOT/home/pi"
    echo "pi:x:1000:1000:,,,:/home/pi:/bin/bash" >"$ROOT/etc/passwd"
    echo "pi:*:19000:0:99999:7:::" >"$ROOT/etc/shadow"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[user]
name = "pi"
password = "$5$salt$FIRSTHASH"
password_encrypted = true
EOF
    rpp apply --phase base >/dev/null 2>&1
    assert_contains "account hash applied" "$(cat "$ROOT/etc/shadow")" "FIRSTHASH"
    rpp apply --phase base >/dev/null 2>&1
    assert_contains "re-apply keeps the account hash" "$(cat "$ROOT/etc/shadow")" "FIRSTHASH"
    assert_ncontains "re-apply does not set the marker as hash" "$(cat "$ROOT/etc/shadow")" "redacted"
    rm -rf "$ROOT"

    # --- Open SSID: no password, no [wifi-security] block (separate sandbox) ---
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware"
    echo "pi:x:1000:1000::/home/pi:/bin/sh" >"$ROOT/etc/passwd"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[wlan]
ssid = "CoffeeShopWiFi"
EOF
    rpp apply --phase base >/dev/null 2>&1
    _ti_nm=$(cat "$ROOT/etc/NetworkManager/system-connections/preconfigured.nmconnection" 2>/dev/null)
    assert_contains "open network ssid written" "$_ti_nm" "ssid=CoffeeShopWiFi"
    assert_ncontains "open network has no wifi-security" "$_ti_nm" "wifi-security"
    assert_ncontains "open network has no psk" "$_ti_nm" "psk="
    rm -rf "$ROOT"

    # --- A passphrase NetworkManager would unescape is escaped (separate sandbox) ---
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware"
    echo "pi:x:1000:1000::/home/pi:/bin/sh" >"$ROOT/etc/passwd"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[wlan]
ssid = "TestNet"
password = " Pa\\ss\\d"
EOF
    rpp apply --phase base >/dev/null 2>&1
    _ti_nm=$(cat "$ROOT/etc/NetworkManager/system-connections/preconfigured.nmconnection" 2>/dev/null)
    assert_contains "psk backslashes and leading space are escaped" "$_ti_nm" 'psk=\sPa\\ss\\d'
    rm -rf "$ROOT"

    # --- Non-UTF-8 SSID via ssid_hex: NM byte-array, WPA2 (separate sandbox) ---
    # "Foo" + a raw 0xfe octet -> 70;111;111;254; . Imager can't carry raw octets,
    # so this must always take the native NM writer.
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware"
    echo "pi:x:1000:1000::/home/pi:/bin/sh" >"$ROOT/etc/passwd"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[wlan]
ssid_hex = "466f6ffe"
password = "hunter2hunter2"
key_mgmt = "wpa-psk"
EOF
    rpp apply --phase base >/dev/null 2>&1
    _ti_nm=$(cat "$ROOT/etc/NetworkManager/system-connections/preconfigured.nmconnection" 2>/dev/null)
    assert_contains "hex ssid written as NM byte-array" "$_ti_nm" "ssid=70;111;111;254;"
    assert_contains "hex ssid honours wpa-psk" "$_ti_nm" "key-mgmt=wpa-psk"
    rm -rf "$ROOT"

    # --- Wi-Fi country offline: regdomain persisted to cmdline.txt (separate) ---
    # raspi-config can't run against a sandbox rootfs, so the country must still be
    # applied via the kernel regdomain rather than silently reported as done.
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware"
    echo "pi:x:1000:1000::/home/pi:/bin/sh" >"$ROOT/etc/passwd"
    printf 'console=serial0,115200 root=PARTUUID=abcd rootwait\n' >"$ROOT/boot/firmware/cmdline.txt"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[wlan]
ssid = "HomeNet"
password = "hunter2hunter2"
country = "GB"
EOF
    rpp apply --phase base >/dev/null 2>&1
    _ti_cmd=$(cat "$ROOT/boot/firmware/cmdline.txt" 2>/dev/null)
    assert_contains "wlan country persisted as kernel regdomain" "$_ti_cmd" "cfg80211.ieee80211_regdom=GB"
    assert_contains "regdomain appended to existing single-line cmdline" "$_ti_cmd" "rootwait cfg80211.ieee80211_regdom=GB"
    # Idempotent: a second explicit apply must not duplicate the parameter.
    rpp apply --phase base >/dev/null 2>&1
    _ti_n=$(grep -o 'cfg80211.ieee80211_regdom=GB' "$ROOT/boot/firmware/cmdline.txt" | wc -l | tr -d ' ')
    assert_eq "regdomain not duplicated on re-apply" "$_ti_n" "1"
    rm -rf "$ROOT"

    # --- Report is cumulative across phases + Connect device-identity capture ---
    # Regression: each phase used to overwrite report.json from fresh scratch, so
    # the final (runcmd-late) artifact had empty keys. Base-phase keys must now
    # survive into the last phase's report.
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware" "$ROOT/home/pi"
    echo "pi:x:1000:1000:,,,:/home/pi:/bin/bash" >"$ROOT/etc/passwd"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[system]
hostname = "cumpi"
[connect]
enabled = true
mode = "device-identity"
[runcmd]
late = ["true"]
EOF
    rpp apply >/dev/null 2>&1
    _ti_rep=$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)
    assert_contains "final report is the runcmd-late phase" "$_ti_rep" '"phase": "runcmd-late"'
    assert_contains "base key survives into final report" "$_ti_rep" "connect.enabled"
    assert_contains "connect device-identity captured in report" "$_ti_rep" "connect.device_identity"
    # The sandbox has no firmware crypto service, so identity state is 'unknown'.
    assert_contains "device-identity unknown without rpi-fw-crypto" "$_ti_rep" "rpi-fw-crypto unavailable"
    rm -rf "$ROOT"

    # --- Connect token mode: the token lands where the daemon reads it --------
    # rpi-connect runs as the user, so auth.key has to be under that user's home
    # and owned by them -- everything an applier writes is created by root. The
    # user here is known only to the target's passwd, which is what resolves it.
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware" "$ROOT/home/alice"
    echo "alice:x:1000:1000:,,,:/home/alice:/bin/bash" >"$ROOT/etc/passwd"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[connect]
enabled = true
mode = "token"
token = "tok-abc-123"
EOF
    rpp apply --phase base >/dev/null 2>&1
    _ti_ak="$ROOT/home/alice/.config/com.raspberrypi.connect/auth.key"
    assert_file "connect auth.key written under the target user's home" "$_ti_ak"
    assert_eq "auth.key holds the token verbatim" "$(cat "$_ti_ak" 2>/dev/null)" "tok-abc-123"
    assert_eq "auth.key is readable only by its owner" "$(stat -c %a "$_ti_ak" 2>/dev/null)" "600"
    _ti_rep=$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)
    assert_contains "connect.token recorded in the report" "$_ti_rep" "connect.token"
    assert_ncontains "token value never reaches the report" "$_ti_rep" "tok-abc-123"
    # No Connect units in this image, so enablement has nothing to do and says so.
    assert_contains "connect.units skipped without rpi-connect" "$_ti_rep" "rpi-connect units not present"
    rm -rf "$ROOT"

    # --- Connect enablement survives a boot with no user manager -------------
    # `rpi-connect on` needs a running user manager and a first boot has none,
    # so enablement has to be static: wants symlinks the account's own manager
    # reads when it next starts, plus lingering so logind starts it at boot.
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware" "$ROOT/home/alice" "$ROOT/usr/lib/systemd/user"
    echo "alice:x:1000:1000:,,,:/home/alice:/bin/bash" >"$ROOT/etc/passwd"
    for _ti_u in rpi-connect.service rpi-connect-wayvnc.service rpi-connect-signin.path; do
        : >"$ROOT/usr/lib/systemd/user/$_ti_u"
    done
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[connect]
enabled = true
mode = "token"
token = "tok-abc-123"
EOF
    rpp apply --phase base >/dev/null 2>&1
    _ti_uw="$ROOT/home/alice/.config/systemd/user"
    assert_ok "rpi-connect.service wanted by default.target" \
        "[ -L $_ti_uw/default.target.wants/rpi-connect.service ]"
    # As systemctl --user enable rpi-connect lays it out: wayvnc and the
    # sign-in path are the service's Also=, wanted by the service itself.
    assert_ok "rpi-connect-wayvnc.service wanted by rpi-connect.service" \
        "[ -L $_ti_uw/rpi-connect.service.wants/rpi-connect-wayvnc.service ]"
    assert_ok "rpi-connect-signin.path wanted by rpi-connect.service" \
        "[ -L $_ti_uw/rpi-connect.service.wants/rpi-connect-signin.path ]"
    assert_fail "nothing left in the old paths.target.wants" \
        "[ -e $_ti_uw/paths.target.wants ]"
    assert_eq "the link names the on-device unit path, not the staging root" \
        "$(readlink "$_ti_uw/default.target.wants/rpi-connect.service")" \
        "/usr/lib/systemd/user/rpi-connect.service"
    assert_file "lingering enabled for the account" "$ROOT/var/lib/systemd/linger/alice"
    assert_contains "connect.units recorded as applied" \
        "$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)" "3 linked, lingering enabled"
    rm -rf "$ROOT"

    # --- SSH fallback keys are not duplicated on re-apply --------------------
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware" "$ROOT/home/alice"
    echo "alice:x:1000:1000:,,,:/home/alice:/bin/bash" >"$ROOT/etc/passwd"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[ssh]
enabled = true
authorized_keys = ["ssh-ed25519 AAAAKEY1 a@b", "ssh-ed25519 AAAAKEY2 c@d"]
EOF
    rpp apply --phase base >/dev/null 2>&1
    rpp apply --phase base >/dev/null 2>&1
    _ti_ak="$ROOT/home/alice/.ssh/authorized_keys"
    assert_eq "both keys installed" "$(grep -c '^ssh-ed25519' "$_ti_ak" 2>/dev/null)" "2"
    assert_eq "first key not duplicated on re-apply" \
        "$(grep -cF 'AAAAKEY1' "$_ti_ak" 2>/dev/null)" "1"
    rm -rf "$ROOT"

    # --- Supplementary groups: rename + add to sudo, preserve/skip correctly ---
    # Imager grants the operator real privileges by listing groups (esp. 'sudo').
    # Membership is append-only; a non-existent group is skipped, not fatal.
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware" "$ROOT/home/pi"
    echo "pi:x:1000:1000:,,,:/home/pi:/bin/bash" >"$ROOT/etc/passwd"
    cat >"$ROOT/etc/group" <<'EOF'
root:x:0:
sudo:x:27:alice
plugdev:x:46:
EOF
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[user]
name = "operator"
groups = ["sudo", "plugdev", "nosuchgroup"]
EOF
    rpp apply --phase base >/dev/null 2>&1
    _ti_grp=$(cat "$ROOT/etc/group" 2>/dev/null)
    assert_eq "renamed user landed in passwd" \
        "$(awk -F: '$3==1000{print $1}' "$ROOT/etc/passwd")" "operator"
    assert_contains "operator added to sudo group" "$_ti_grp" "sudo:x:27:alice,operator"
    assert_contains "operator added to plugdev group" "$_ti_grp" "plugdev:x:46:operator"
    _ti_rep=$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)
    assert_contains "groups applied reported" "$_ti_rep" "sudo,plugdev"
    assert_contains "missing group skipped in report" "$_ti_rep" "nosuchgroup"
    # Idempotent: a second apply must not duplicate the membership.
    rpp apply --phase base >/dev/null 2>&1
    _ti_n=$(awk -F: '$1=="sudo"{print $4}' "$ROOT/etc/group" | grep -o 'operator' | wc -l | tr -d ' ')
    assert_eq "sudo membership not duplicated on re-apply" "$_ti_n" "1"
    rm -rf "$ROOT"

    # --- Groups without a rename: apply to the current UID 1000 account ---
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware" "$ROOT/home/pi"
    echo "pi:x:1000:1000:,,,:/home/pi:/bin/bash" >"$ROOT/etc/passwd"
    printf 'sudo:x:27:\n' >"$ROOT/etc/group"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[user]
groups = ["sudo"]
EOF
    rpp apply --phase base >/dev/null 2>&1
    assert_contains "groups apply without a rename" \
        "$(cat "$ROOT/etc/group" 2>/dev/null)" "sudo:x:27:pi"
    rm -rf "$ROOT"

    # --- Ethernet: static + dhcp NetworkManager keyfiles (separate sandbox) ---
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware"
    echo "pi:x:1000:1000::/home/pi:/bin/sh" >"$ROOT/etc/passwd"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.1"
[ethernet]
method = "static"
address = "192.168.1.50/24"
gateway = "192.168.1.1"
dns = ["192.168.1.1", "1.1.1.1"]
interface = "eth0"
EOF
    rpp apply --phase base >/dev/null 2>&1
    _ti_eth=$(cat "$ROOT/etc/NetworkManager/system-connections/preconfigured-ethernet.nmconnection" 2>/dev/null)
    assert_contains "ethernet keyfile is wired type" "$_ti_eth" "type=ethernet"
    assert_contains "ethernet binds named interface" "$_ti_eth" "interface-name=eth0"
    assert_contains "ethernet static method" "$_ti_eth" "method=manual"
    assert_contains "ethernet static address+gateway" "$_ti_eth" "address1=192.168.1.50/24,192.168.1.1"
    assert_contains "ethernet dns list" "$_ti_eth" "dns=192.168.1.1;1.1.1.1;"
    rm -rf "$ROOT"

    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware"
    echo "pi:x:1000:1000::/home/pi:/bin/sh" >"$ROOT/etc/passwd"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    printf 'config_version = "1.1"\n[ethernet]\nmethod = "dhcp"\n' >"$CFG"
    rpp apply --phase base >/dev/null 2>&1
    assert_contains "ethernet dhcp method auto" \
        "$(cat "$ROOT/etc/NetworkManager/system-connections/preconfigured-ethernet.nmconnection" 2>/dev/null)" "method=auto"
    rm -rf "$ROOT"

    # --- CA certs / NTP / mounts base-phase appliers (separate sandbox) ---
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware"
    echo "pi:x:1000:1000::/home/pi:/bin/sh" >"$ROOT/etc/passwd"
    printf -- '-----BEGIN CERTIFICATE-----\nMIIfake\n-----END CERTIFICATE-----\n' >"$ROOT/boot/firmware/corp-root-ca.crt"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.1"
[time]
ntp = ["time.cloudflare.com"]
fallback_ntp = ["0.debian.pool.ntp.org"]
[ca_certificates]
files = ["corp-root-ca.crt", "missing.crt"]
[mounts]
fstab = ["LABEL=DATA /data ext4 defaults,nofail 0 2"]
EOF
    rpp apply --phase base >/dev/null 2>&1
    assert_contains "timesyncd NTP written" \
        "$(cat "$ROOT/etc/systemd/timesyncd.conf.d/10-rpi-preseed.conf" 2>/dev/null)" "NTP=time.cloudflare.com"
    assert_contains "timesyncd FallbackNTP written" \
        "$(cat "$ROOT/etc/systemd/timesyncd.conf.d/10-rpi-preseed.conf" 2>/dev/null)" "FallbackNTP=0.debian.pool.ntp.org"
    assert_file "CA cert staged for update-ca-certificates" "$ROOT/usr/local/share/ca-certificates/corp-root-ca.crt"
    assert_contains "missing CA cert reported skipped" \
        "$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)" "missing.crt"
    assert_contains "fstab entry appended" "$(cat "$ROOT/etc/fstab" 2>/dev/null)" "LABEL=DATA /data ext4"
    if [ -d "$ROOT/data" ]; then ok "fstab mountpoint dir created"; else no "fstab mountpoint dir created"; fi
    # Idempotent: re-apply must not duplicate the fstab line.
    rpp apply --phase base >/dev/null 2>&1
    _ti_n=$(grep -c 'LABEL=DATA /data ext4' "$ROOT/etc/fstab" 2>/dev/null | tr -d ' ')
    assert_eq "fstab line not duplicated on re-apply" "$_ti_n" "1"
    rm -rf "$ROOT"

    # --- Keyboard: layout must reach the labwc compositor, not just the console.
    # Writing only /etc/default/keyboard leaves labwc on its packaged default
    # layout, so the desktop ignores the chosen keymap (trixie-feedback#67). The
    # full-XKB fallback must create the per-user labwc environment override and
    # update an existing greeter environment in place, keeping unrelated lines.
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware" "$ROOT/home/pi" "$ROOT/etc/xdg/labwc-greeter"
    echo "pi:x:1000:1000:,,,:/home/pi:/bin/bash" >"$ROOT/etc/passwd"
    printf 'XKB_DEFAULT_LAYOUT=gb\nGDK_BACKEND=wayland\n' >"$ROOT/etc/xdg/labwc-greeter/environment"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[locale]
keymap = "fr"
keymap_variant = "azerty"
keymap_options = ["ctrl:nocaps"]
EOF
    rpp apply --phase base >/dev/null 2>&1
    _ti_lenv="$ROOT/home/pi/.config/labwc/environment"
    assert_file "labwc per-user environment created" "$_ti_lenv"
    assert_contains "labwc layout matches chosen keymap" "$(cat "$_ti_lenv" 2>/dev/null)" "XKB_DEFAULT_LAYOUT=fr"
    assert_contains "labwc variant matches chosen keymap" "$(cat "$_ti_lenv" 2>/dev/null)" "XKB_DEFAULT_VARIANT=azerty"
    assert_contains "labwc options match chosen keymap" "$(cat "$_ti_lenv" 2>/dev/null)" "XKB_DEFAULT_OPTIONS=ctrl:nocaps"
    _ti_genv="$ROOT/etc/xdg/labwc-greeter/environment"
    assert_contains "labwc greeter layout updated" "$(cat "$_ti_genv" 2>/dev/null)" "XKB_DEFAULT_LAYOUT=fr"
    assert_contains "labwc greeter preserves unrelated lines" "$(cat "$_ti_genv" 2>/dev/null)" "GDK_BACKEND=wayland"
    assert_ncontains "labwc greeter drops stale layout" "$(cat "$_ti_genv" 2>/dev/null)" "XKB_DEFAULT_LAYOUT=gb"
    # Idempotent: re-apply must not duplicate the XKB keys.
    rpp apply --phase base >/dev/null 2>&1
    _ti_n=$(grep -c '^XKB_DEFAULT_LAYOUT=' "$_ti_lenv" 2>/dev/null | tr -d ' ')
    assert_eq "labwc layout key not duplicated on re-apply" "$_ti_n" "1"
    rm -rf "$ROOT"

    # --- Packages: sandbox has no apt-get, so the request is reported skipped ---
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware"
    echo "pi:x:1000:1000::/home/pi:/bin/sh" >"$ROOT/etc/passwd"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.1"
[packages]
update = true
install = ["vim", "htop"]
EOF
    rpp apply --phase late >/dev/null 2>&1
    assert_file "late stamp written for packages-only config" "$ROOT/var/lib/rpi-preseed/runcmd-done"
    assert_contains "packages reported skipped without apt-get" \
        "$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)" "apt-get unavailable"
    rm -rf "$ROOT"

    # --- [[users]]: create new accounts; an existing one has its password reset ---
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc/skel" "$ROOT/boot/firmware" "$ROOT/home/pi" "$ROOT/home/carol"
    echo "skel" >"$ROOT/etc/skel/.profile"
    cat >"$ROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
pi:x:1000:1000:,,,:/home/pi:/bin/bash
carol:x:1001:1001:,,,:/home/carol:/bin/bash
EOF
    printf 'root:*:19000:0:99999:7:::\npi:*:19000:0:99999:7:::\ncarol:OLDHASH:19000:0:99999:7:::\n' >"$ROOT/etc/shadow"
    printf 'root:x:0:\npi:x:1000:\ncarol:x:1001:\ngpio:x:997:\n' >"$ROOT/etc/group"
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'EOF'
config_version = "1.0"
[[users]]
name = "bob"
password = "$5$salt$BOBHASH"
password_encrypted = true
groups = ["gpio"]
authorized_keys = ["ssh-ed25519 AAAA bob@host"]
passwordless_sudo = true
[[users]]
name = "carol"
password = "$5$salt$CAROLHASH"
password_encrypted = true
[[users]]
name = "root"
password = "$5$salt$ROOTHASH"
password_encrypted = true
EOF
    rpp apply --phase base >/dev/null 2>&1
    assert_contains "new user in passwd" "$(cat "$ROOT/etc/passwd")" "bob:x:1002:1002::/home/bob:/bin/bash"
    assert_contains "new user's own group" "$(cat "$ROOT/etc/group")" "bob:x:1002:"
    assert_contains "new user added to gpio" "$(cat "$ROOT/etc/group")" "gpio:x:997:bob"
    assert_contains "new user's hash" "$(cat "$ROOT/etc/shadow")" "bob:\$5\$salt\$BOBHASH:"
    assert_file "new user's home from skel" "$ROOT/home/bob/.profile"
    assert_contains "new user's key" "$(cat "$ROOT/home/bob/.ssh/authorized_keys" 2>/dev/null)" "bob@host"
    assert_file "new user's sudoers drop-in" "$ROOT/etc/sudoers.d/010_rpi-preseed-nopasswd"
    assert_contains "existing user's password reset" "$(cat "$ROOT/etc/shadow")" "carol:\$5\$salt\$CAROLHASH:"
    assert_contains "reset is warned about" "$(cat "$ROOT/var/lib/rpi-preseed/log/base.log" 2>/dev/null)" "resetting its password"
    assert_contains "system account left alone" "$(cat "$ROOT/etc/shadow")" "root:*:"
    assert_contains "system account refusal reported" "$(cat "$ROOT/var/lib/rpi-preseed/report.json")" "system account"
    assert_ncontains "[[users]] passwords redacted from the config" "$(cat "$CFG")" "BOBHASH"
    # Re-apply: nobody is created twice and consumed passwords stay put.
    rpp apply --phase base >/dev/null 2>&1
    assert_eq "re-apply creates no duplicate" "$(grep -c '^bob:' "$ROOT/etc/passwd")" "1"
    assert_contains "re-apply keeps the new user's hash" "$(cat "$ROOT/etc/shadow")" "bob:\$5\$salt\$BOBHASH:"
    rm -rf "$ROOT"

    # --- A per-device config on the persistent partition wins over the boot one ---
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc" "$ROOT/boot/firmware" "$ROOT/persistent" "$ROOT/home/pi"
    echo "pi:x:1000:1000:,,,:/home/pi:/bin/bash" >"$ROOT/etc/passwd"
    printf 'config_version = "1.0"\n[system]\nhostname = "fromboot"\n' >"$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$ROOT/persistent/rpi-preseed.toml" <<'EOF'
config_version = "1.0"
[system]
hostname = "frompersistent"
[wlan]
ssid = "Net"
password = "wifipassword1"
EOF
    env -u RPI_PRESEED_STATE_DIR -u RPI_PRESEED_BOOT_DIR RPI_PRESEED_ROOT="$ROOT" \
        sh "$RPI_PRESEED_SRCDIR/rpi-preseed" apply --phase base >/dev/null 2>&1
    assert_eq "persistent config preferred" "$(cat "$ROOT/etc/hostname" 2>/dev/null)" "frompersistent"
    assert_ncontains "persistent config redacted" "$(cat "$ROOT/persistent/rpi-preseed.toml")" "wifipassword1"
    rm -rf "$ROOT"

    # --- Read-only targets, as on an immutable image (image-rota) ---
    # Real read-only bind mounts need a user namespace; skip where there is none.
    if unshare -rm true 2>/dev/null; then
        ROOT=$(mktemp -d)
        mkdir -p "$ROOT/etc" "$ROOT/boot/firmware" "$ROOT/var" "$ROOT/home/pi"
        echo "pi:x:1000:1000:,,,:/home/pi:/bin/bash" >"$ROOT/etc/passwd"
        echo raspberrypi >"$ROOT/etc/hostname"
        printf '127.0.1.1\traspberrypi\n' >"$ROOT/etc/hosts"
        : >"$ROOT/boot/firmware/config.txt"
        CFG="$ROOT/boot/firmware/rpi-preseed.toml"
        cat >"$CFG" <<'EOF'
config_version = "1.0"
[system]
hostname = "rota"
[wlan]
ssid = "Net"
password = "wifipassword1"
[boot]
config_txt = ["dtparam=audio=on"]
EOF
        mkdir -p "$ROOT/etc/NetworkManager/system-connections"
        # _ti_ro "RO..." "RW..." [discover] — base apply with each RO dir
        # (under ROOT) read-only, then each RW dir writable again, as
        # image-rota's shared bind mounts are. "discover" leaves rpi-preseed
        # to find the config itself.
        _ti_ro() {
            # shellcheck disable=SC2016  # expanded by the inner shell
            unshare -rm sh -c '
                r=$1
                for d in $2; do
                    mount --bind "$r$d" "$r$d" && mount -o remount,bind,ro "$r$d" || exit 99
                done
                for d in $3; do
                    mount --bind "$r$d" "$r$d" && mount -o remount,bind,rw "$r$d" || exit 99
                done
                unset RPI_PRESEED_STATE_DIR RPI_PRESEED_BOOT_DIR
                [ "$4" = discover ] || export RPI_PRESEED_CONFIG="$r/boot/firmware/rpi-preseed.toml"
                RPI_PRESEED_ROOT="$r" sh "$RPI_PRESEED_SRCDIR/rpi-preseed" apply --phase base
            ' sh "$ROOT" "$1" "$2" "${3:-}" >/dev/null 2>&1
        }
        _ti_rc=0
        _ti_ro "/ /boot/firmware" "/var /home /etc/NetworkManager/system-connections" || _ti_rc=$?
        _ti_rep=$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)
        assert_eq "read-only root: apply completes" "$_ti_rc" "0"
        assert_eq "read-only root: hostname untouched" "$(cat "$ROOT/etc/hostname")" "raspberrypi"
        assert_contains "read-only root: hostname reported skipped" "$_ti_rep" \
            '"key": "system.hostname", "status": "skipped", "detail": "read-only filesystem"'
        assert_ncontains "read-only root: nothing read-only reported applied" "$_ti_rep" \
            '"key": "system.hostname", "status": "applied"'
        assert_contains "read-only root: Wi-Fi lands in the shared directory" \
            "$(cat "$ROOT/etc/NetworkManager/system-connections/preconfigured.nmconnection" 2>/dev/null)" "ssid=Net"

        # Accounts on a read-only /etc go to userdb records, which need
        # nss-systemd; an account baked into the image is left alone.
        rm -rf "$ROOT/var/lib"
        cp "$CFG" "$CFG.orig"
        mkdir -p "$ROOT/etc/userdb" "$ROOT/etc/skel"
        echo skel >"$ROOT/etc/skel/.profile"
        printf 'root:x:0:\nsudo:x:27:\npi:x:1000:\n' >"$ROOT/etc/group"
        printf 'passwd: files systemd\ngroup: files systemd\nshadow: files systemd\n' >"$ROOT/etc/nsswitch.conf"
        cat >"$CFG" <<'EOF'
config_version = "1.0"
[[users]]
name = "bob"
password = "$y$j9T$salt$BOBHASH"
password_encrypted = true
groups = ["sudo"]
authorized_keys = ["ssh-ed25519 AAAA bob@host"]
[[users]]
name = "pi"
password = "$y$j9T$salt$PIHASH"
password_encrypted = true
EOF
        _ti_ro "/ /boot/firmware" "/var /home /etc/userdb"
        _ti_ud="$ROOT/etc/userdb"
        _ti_rep=$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)
        assert_contains "userdb: account record" "$(cat "$_ti_ud/bob.user" 2>/dev/null)" '"userName":"bob","uid":59999,"gid":59999'
        assert_eq "userdb: lookup by number" "$(readlink "$_ti_ud/59999.user")" "bob.user"
        assert_contains "userdb: own group" "$(cat "$_ti_ud/bob.group" 2>/dev/null)" '"groupName":"bob","gid":59999'
        assert_contains "userdb: password hash" "$(cat "$_ti_ud/bob.user-privileged" 2>/dev/null)" 'BOBHASH'
        assert_eq "userdb: hash readable by root alone" "$(stat -c %a "$_ti_ud/bob.user-privileged" 2>/dev/null)" "600"
        assert_eq "userdb: sudo membership not empty" "$(wc -c <"$_ti_ud/bob:sudo.membership" 2>/dev/null | tr -d ' ')" "1"
        assert_file "userdb: home from skel" "$ROOT/home/bob/.profile"
        assert_contains "userdb: key in the home" "$(cat "$ROOT/home/bob/.ssh/authorized_keys" 2>/dev/null)" "bob@host"
        assert_fail "userdb: image account untouched" "[ -e '$_ti_ud/pi.user-privileged' ]"
        assert_contains "userdb: image account reported skipped" "$_ti_rep" \
            '"key": "users.1.name", "status": "skipped", "detail": "read-only filesystem"'
        if command -v python3 >/dev/null 2>&1; then
            assert_ok "userdb: records are JSON" \
                "for f in '$_ti_ud'/*.user '$_ti_ud'/*.group '$_ti_ud'/*.user-privileged; do python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \"\$f\" || exit 1; done"
        fi
        # Without nss-systemd the accounts could not log in, so it fails.
        rm -rf "$ROOT/var/lib" "${_ti_ud:?}"/* "$ROOT/home/bob"
        echo 'passwd: files' >"$ROOT/etc/nsswitch.conf"
        sed -i 's/BOBHASH/BOBHASH2/' "$CFG"
        _ti_ro "/ /boot/firmware" "/var /home /etc/userdb"
        assert_contains "userdb: missing nss-systemd reported failed" \
            "$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)" \
            '"key": "users.0.name", "status": "failed", "detail": "libnss-systemd missing"'
        assert_fail "userdb: nothing written without nss-systemd" "[ -e '$_ti_ud/bob.user' ]"
        mv "$CFG.orig" "$CFG"

        # What Imager writes, unchanged, onto /bootfs (the first partition):
        # [user] cannot rename the image's account, so it becomes a userdb
        # account, and [ssh]'s keys go to it rather than to UID 1000.
        rm -rf "$ROOT/var/lib" "${_ti_ud:?}"/* "$ROOT/home/bob"
        printf 'passwd: files systemd\ngroup: files systemd\nshadow: files systemd\n' >"$ROOT/etc/nsswitch.conf"
        mkdir -p "$ROOT/bootfs"
        mv "$CFG" "$CFG.orig"
        cat >"$ROOT/bootfs/rpi-preseed.toml" <<'EOF'
config_version = "1.0"
[user]
name = "alice"
password = "$y$j9T$salt$ALICEHASH"
password_encrypted = true
groups = ["sudo"]
[ssh]
enabled = true
authorized_keys = ["ssh-ed25519 AAAA alice@laptop"]
EOF
        _ti_ro "/ /boot/firmware" "/var /home /etc/userdb /bootfs" discover
        _ti_rep=$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)
        assert_contains "Imager [user]: made in userdb" "$(cat "$_ti_ud/alice.user" 2>/dev/null)" '"userName":"alice"'
        assert_contains "Imager [user]: hash" "$(cat "$_ti_ud/alice.user-privileged" 2>/dev/null)" 'ALICEHASH'
        assert_file "Imager [user]: sudo membership" "$_ti_ud/alice:sudo.membership"
        assert_contains "Imager [user]: reported created" "$_ti_rep" '"key": "user.name", "status": "applied", "detail": "created"'
        assert_contains "Imager [ssh]: keys go to that account" \
            "$(cat "$ROOT/home/alice/.ssh/authorized_keys" 2>/dev/null)" "alice@laptop"
        assert_fail "Imager [ssh]: not to the image's own account" "[ -e '$ROOT/home/pi/.ssh/authorized_keys' ]"
        assert_ncontains "Imager config on /bootfs redacted" "$(cat "$ROOT/bootfs/rpi-preseed.toml")" "ALICEHASH"
        mv "$CFG.orig" "$CFG"

        rm -rf "$ROOT/var/lib"
        _ti_rc=0
        _ti_ro /boot/firmware /var || _ti_rc=$?
        _ti_rep=$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)
        assert_eq "read-only boot: apply succeeds" "$_ti_rc" "0"
        assert_eq "read-only boot: hostname still applied" "$(cat "$ROOT/etc/hostname")" "rota"
        assert_ncontains "read-only boot: config.txt untouched" "$(cat "$ROOT/boot/firmware/config.txt")" "audio"
        assert_contains "read-only boot: config.txt reported skipped" "$_ti_rep" "read-only filesystem"
        assert_contains "read-only boot: plain-text secrets warned" \
            "$(cat "$ROOT/var/lib/rpi-preseed/log/base.log" 2>/dev/null)" "stay on it in plain text"
        rm -rf "$ROOT"
    else
        echo "skip - read-only targets (no user namespaces)"
    fi
}

# An A/B image's /etc is a writable tmpfs overlay: only what its slot-state
# manifest keeps survives a reboot, so nothing else may be reported applied.
t_slot_state() {
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/etc/sudoers.d" "$ROOT/boot/firmware" "$ROOT/home/pi" "$ROOT/usr/lib/rpi-image-gen"
    echo "pi:x:1000:1000:,,,:/home/pi:/bin/bash" >"$ROOT/etc/passwd"
    echo "pi:*:19000:0:99999:7:::" >"$ROOT/etc/shadow"
    printf 'pi:x:1000:\nsudo:x:27:\n' >"$ROOT/etc/group"
    printf 'pi:!::\nsudo:*::\n' >"$ROOT/etc/gshadow"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\traspberrypi\n' >"$ROOT/etc/hosts"
    _ss_m="$ROOT/usr/lib/rpi-image-gen/slot-state.manifest"
    _ss_decl() {
        echo "# op path store seed bind" >"$_ss_m"
        for _ss_f in hostname hosts passwd group shadow gshadow "$@"; do
            echo "EarlyPersistFile /etc/$_ss_f /persistent/common/etc/$_ss_f - -" >>"$_ss_m"
        done
        echo "SharedPath /var/lib/rpi-preseed /persistent/shared/var/lib/rpi-preseed /usr/share/factory/var/lib/rpi-preseed optional" >>"$_ss_m"
    }
    CFG="$ROOT/boot/firmware/rpi-preseed.toml"
    cat >"$CFG" <<'TOML'
config_version = "1.0"
[system]
hostname = "rota"
[locale]
keymap = "gb"
[user]
name = "alice"
password = "$y$j9T$salt$ALICEHASH"
password_encrypted = true
passwordless_sudo = true
groups = ["sudo"]
TOML
    rpp() {
        env -u RPI_PRESEED_STATE_DIR -u RPI_PRESEED_BOOT_DIR \
            RPI_PRESEED_ROOT="$ROOT" RPI_PRESEED_CONFIG="$CFG" \
            sh "$RPI_PRESEED_SRCDIR/rpi-preseed" apply --phase base >/dev/null 2>&1
    }
    cp "$CFG" "$CFG.orig"
    _ss_decl
    rpp
    _ss_rep=$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)
    assert_eq "slot-state: kept hostname applied" "$(cat "$ROOT/etc/hostname" 2>/dev/null)" "rota"
    assert_contains "slot-state: unkept keymap skipped" "$_ss_rep" \
        '"key": "locale.keymap", "status": "skipped", "detail": "not persisted"'
    assert_fail "slot-state: unkept keymap not written" "[ -e '$ROOT/etc/default/keyboard' ]"
    assert_contains "slot-state: rename reported" "$_ss_rep" '"key": "user.name", "status": "applied", "detail": "fallback"'
    assert_contains "slot-state: hash on the renamed account" "$(cat "$ROOT/etc/shadow")" "alice:\$y\$j9T\$salt\$ALICEHASH:"
    assert_contains "slot-state: group renamed" "$(cat "$ROOT/etc/group")" "alice:x:1000:"
    assert_contains "slot-state: home renamed" "$(cat "$ROOT/etc/passwd")" "alice:x:1000:1000:,,,:/home/alice:"
    assert_contains "slot-state: unkept sudoers skipped" "$_ss_rep" \
        '"key": "user.passwordless_sudo", "status": "skipped", "detail": "not persisted"'

    # The save runs before the config is consumed; if it fails, nothing is.
    rm -rf "$ROOT/var/lib"; cp "$CFG.orig" "$CFG"
    sed -i 's/^alice:/pi:/' "$ROOT/etc/passwd" "$ROOT/etc/shadow" "$ROOT/etc/group" "$ROOT/etc/gshadow"
    mv "$ROOT/home/alice" "$ROOT/home/pi"
    _ss_save="$ROOT/save"
    # shellcheck disable=SC2016  # expanded by the stub
    printf '#!/bin/sh\n[ -e "%s/var/lib/rpi-preseed/applied" ] && echo late >>"%s/saved"\ngrep -c ALICEHASH "%s/boot/firmware/rpi-preseed.toml" >>"%s/saved"\n' \
        "$ROOT" "$ROOT" "$ROOT" "$ROOT" >"$_ss_save"
    chmod +x "$_ss_save"
    SLOT_STATE_SAVE="$_ss_save" rpp
    assert_eq "slot-state: saved before stamp and redaction" "$(cat "$ROOT/saved" 2>/dev/null)" "1"
    assert_file "slot-state: stamped after the save" "$ROOT/var/lib/rpi-preseed/applied"
    rm -rf "$ROOT/var/lib"; cp "$CFG.orig" "$CFG"
    sed -i 's/^alice:/pi:/' "$ROOT/etc/passwd" "$ROOT/etc/shadow" "$ROOT/etc/group" "$ROOT/etc/gshadow"
    mv "$ROOT/home/alice" "$ROOT/home/pi"
    printf '#!/bin/sh\nexit 1\n' >"$_ss_save"
    _ss_rc=0; SLOT_STATE_SAVE="$_ss_save" rpp || _ss_rc=$?
    assert_eq "slot-state: failed save fails the apply" "$_ss_rc" "1"
    assert_fail "slot-state: failed save leaves no applied stamp" "[ -e '$ROOT/var/lib/rpi-preseed/applied' ]"
    assert_contains "slot-state: failed save keeps the secrets" "$(cat "$CFG")" "ALICEHASH"

    # With the sudoers file declared, it lands.
    rm -rf "$ROOT/var/lib"; cp "$CFG.orig" "$CFG"
    _ss_decl sudoers.d/010_rpi-preseed-nopasswd
    rpp
    assert_eq "slot-state: kept sudoers written" \
        "$(cat "$ROOT/etc/sudoers.d/010_rpi-preseed-nopasswd" 2>/dev/null)" "alice ALL=(ALL) NOPASSWD: ALL"

    # Account files not kept, and no userdb: the account is not touched.
    rm -rf "$ROOT/var/lib"; cp "$CFG.orig" "$CFG"
    sed -i '/passwd\|shadow\|group/d' "$_ss_m"
    sed -i 's/^alice:/pi:/' "$ROOT/etc/passwd"
    rpp
    assert_contains "slot-state: unkept accounts skipped" "$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)" \
        '"key": "user.name", "status": "skipped", "detail": "not persisted"'
    assert_contains "slot-state: unkept passwd untouched" "$(cat "$ROOT/etc/passwd")" "pi:x:1000:"

    # No UID 1000 account in the image: [user] makes one.
    rm -rf "$ROOT/var/lib" "$ROOT/home/alice"; cp "$CFG.orig" "$CFG"
    _ss_decl
    echo "root:x:0:0::/root:/bin/sh" >"$ROOT/etc/passwd"
    echo "root:*:19000:0:99999:7:::" >"$ROOT/etc/shadow"
    printf 'root:x:0:\nsudo:x:27:\n' >"$ROOT/etc/group"
    rpp
    assert_contains "no UID 1000: account created" "$(cat "$ROOT/etc/passwd")" "alice:x:1000:1000::/home/alice:/bin/bash"
    assert_contains "no UID 1000: reported created" "$(cat "$ROOT/var/lib/rpi-preseed/report.json" 2>/dev/null)" \
        '"key": "user.name", "status": "applied", "detail": "created"'
    assert_contains "no UID 1000: hash set" "$(cat "$ROOT/etc/shadow")" "ALICEHASH"
    rm -rf "$ROOT"
}
