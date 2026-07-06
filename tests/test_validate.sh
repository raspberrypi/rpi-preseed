# shellcheck shell=dash
# Validator + version-policy tests.

t_validate() {
    # Valid config passes.
    _tv_f=$(mktemp)
    cat >"$_tv_f" <<'EOF'
config_version = "1.0"
[system]
hostname = "ok"
[connect]
enabled = true
mode = "token"
token = "abc"
[interfaces]
serial = "console"
EOF
    toml_parse "$_tv_f"
    assert_ok "valid config validates" 'validate_config'
    assert_ok "valid version accepted" 'validate_version'
    toml_cleanup

    # Missing required config_version fails.
    _tv_f2=$(mktemp)
    cat >"$_tv_f2" <<'EOF'
[system]
hostname = "x"
EOF
    toml_parse "$_tv_f2"
    assert_fail "missing config_version fails" 'validate_config'
    toml_cleanup

    # Bad enum fails.
    _tv_f3=$(mktemp)
    cat >"$_tv_f3" <<'EOF'
config_version = "1.0"
[interfaces]
serial = "bogus"
EOF
    toml_parse "$_tv_f3"
    assert_fail "invalid enum fails" 'validate_config'
    toml_cleanup

    # connect combo: token mode without token fails.
    _tv_f4=$(mktemp)
    cat >"$_tv_f4" <<'EOF'
config_version = "1.0"
[connect]
mode = "token"
EOF
    toml_parse "$_tv_f4"
    assert_fail "token mode without token fails" 'validate_config'
    toml_cleanup

    # Unknown key is tolerated (validation still succeeds).
    _tv_f5=$(mktemp)
    cat >"$_tv_f5" <<'EOF'
config_version = "1.0"
[system]
hostname = "x"
future_thing = "whatever"
EOF
    toml_parse "$_tv_f5"
    assert_ok "unknown key tolerated" 'validate_config'
    toml_cleanup

    # Hostname: RFC 1123 valid accepted; invalid forms rejected.
    _tv_hn() { printf 'config_version = "1.0"\n[system]\nhostname = "%s"\n' "$1"; }
    for _h in my-pi raspberrypi pi5 a; do
        _tv_hf=$(mktemp); _tv_hn "$_h" >"$_tv_hf"; toml_parse "$_tv_hf"
        assert_ok "valid hostname '$_h'" 'validate_config'; toml_cleanup; rm -f "$_tv_hf"
    done
    for _h in -lead trail- 'has_underscore' 'bad!' 'myπ'; do
        _tv_hf=$(mktemp); _tv_hn "$_h" >"$_tv_hf"; toml_parse "$_tv_hf"
        assert_fail "invalid hostname '$_h' rejected" 'validate_config'; toml_cleanup; rm -f "$_tv_hf"
    done

    # Wi-Fi PSK: octet-length rules (UTF-8 allowed), raw PMK, and SAE leniency.
    _tv_psk() { { printf 'config_version = "1.0"\n[wlan]\nssid = "n"\n'; printf 'password = "%s"\n' "$1"; [ -n "$2" ] && printf 'key_mgmt = "%s"\n' "$2"; } ; }
    _tv_pf=$(mktemp); _tv_psk "short7x" "" >"$_tv_pf"; toml_parse "$_tv_pf"
    assert_fail "wpa-psk 7-octet passphrase rejected" 'validate_config'; toml_cleanup; rm -f "$_tv_pf"
    _tv_pf=$(mktemp); _tv_psk "goodpass" "" >"$_tv_pf"; toml_parse "$_tv_pf"
    assert_ok "wpa-psk 8-octet passphrase accepted" 'validate_config'; toml_cleanup; rm -f "$_tv_pf"
    # 21 emoji = 84 octets > 63: too long for wpa-psk.
    _tv_pf=$(mktemp); _tv_psk "$(printf '\360\237\224\220%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21)" "" >"$_tv_pf"; toml_parse "$_tv_pf"
    assert_fail "wpa-psk >63 octets rejected" 'validate_config'; toml_cleanup; rm -f "$_tv_pf"
    # Non-ASCII but within 63 octets is fine for wpa-psk (correction to old ASCII-only claim).
    _tv_pf=$(mktemp); _tv_psk "sÜper–secret–🔐" "" >"$_tv_pf"; toml_parse "$_tv_pf"
    assert_ok "wpa-psk non-ASCII within 63 octets accepted" 'validate_config'; toml_cleanup; rm -f "$_tv_pf"
    # Same long passphrase is fine under SAE (WPA3).
    _tv_pf=$(mktemp); _tv_psk "$(printf '\360\237\224\220%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21)" "sae" >"$_tv_pf"; toml_parse "$_tv_pf"
    assert_ok "sae long passphrase accepted" 'validate_config'; toml_cleanup; rm -f "$_tv_pf"
    # 64 hex chars = raw PMK, accepted.
    _tv_pf=$(mktemp); _tv_psk "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" "" >"$_tv_pf"; toml_parse "$_tv_pf"
    assert_ok "raw 64-hex PMK accepted" 'validate_config'; toml_cleanup; rm -f "$_tv_pf"

    # Open networks: ssid alone (no password) is a valid open network.
    _tv_of=$(mktemp); printf 'config_version = "1.0"\n[wlan]\nssid = "OpenNet"\n' >"$_tv_of"; toml_parse "$_tv_of"
    assert_ok "open network (ssid only) accepted" 'validate_config'; toml_cleanup; rm -f "$_tv_of"
    # Explicit key_mgmt=none / owe accepted without a password.
    _tv_of=$(mktemp); printf 'config_version = "1.0"\n[wlan]\nssid = "OpenNet"\nkey_mgmt = "owe"\n' >"$_tv_of"; toml_parse "$_tv_of"
    assert_ok "owe (enhanced open) accepted" 'validate_config'; toml_cleanup; rm -f "$_tv_of"
    # A password with an open scheme is a misconfiguration.
    _tv_of=$(mktemp); printf 'config_version = "1.0"\n[wlan]\nssid = "OpenNet"\nkey_mgmt = "none"\npassword = "oops1234"\n' >"$_tv_of"; toml_parse "$_tv_of"
    assert_fail "password with open network rejected" 'validate_config'; toml_cleanup; rm -f "$_tv_of"
    # A secured scheme without a password is rejected.
    _tv_of=$(mktemp); printf 'config_version = "1.0"\n[wlan]\nssid = "SecNet"\nkey_mgmt = "wpa-psk"\n' >"$_tv_of"; toml_parse "$_tv_of"
    assert_fail "wpa-psk without password rejected" 'validate_config'; toml_cleanup; rm -f "$_tv_of"

    # ssid_hex: non-UTF-8 SSID carried as an even run of hex digits.
    _tv_of=$(mktemp); printf 'config_version = "1.0"\n[wlan]\nssid_hex = "466f6ffe"\n' >"$_tv_of"; toml_parse "$_tv_of"
    assert_ok "ssid_hex (open, valid hex) accepted" 'validate_config'; toml_cleanup; rm -f "$_tv_of"
    _tv_of=$(mktemp); printf 'config_version = "1.0"\n[wlan]\nssid_hex = "466f6"\n' >"$_tv_of"; toml_parse "$_tv_of"
    assert_fail "ssid_hex odd length rejected" 'validate_config'; toml_cleanup; rm -f "$_tv_of"
    _tv_of=$(mktemp); printf 'config_version = "1.0"\n[wlan]\nssid_hex = "zzzz"\n' >"$_tv_of"; toml_parse "$_tv_of"
    assert_fail "ssid_hex non-hex rejected" 'validate_config'; toml_cleanup; rm -f "$_tv_of"

    # Version policy: future major refused, future minor warned-but-ok.
    _tv_f6=$(mktemp); printf 'config_version = "2.0"\n' >"$_tv_f6"
    toml_parse "$_tv_f6"; assert_fail "future major refused" 'validate_version'; toml_cleanup
    _tv_f7=$(mktemp); printf 'config_version = "1.9"\n' >"$_tv_f7"
    toml_parse "$_tv_f7"; assert_ok "future minor proceeds" 'validate_version'; toml_cleanup

    rm -f "$_tv_f" "$_tv_f2" "$_tv_f3" "$_tv_f4" "$_tv_f5" "$_tv_f6" "$_tv_f7"
}
