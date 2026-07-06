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
            sh "$REPO/src/rpi-preseed" "$@"
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

    # --- collect-logs excludes runcmd output by default ---
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
}
