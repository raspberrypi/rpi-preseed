# shellcheck shell=dash
# TOML parser tests.

t_toml() {
    _tt_f=$(mktemp)
    cat >"$_tt_f" <<'EOF'
config_version = "1.0"

[system]
hostname = "mypi"          # inline comment must be stripped

[user]
name = 'alice'
password_encrypted = false

[ssh]
enabled = true
authorized_keys = [
  "ssh-ed25519 AAAA one@host",
  "ssh-rsa BBBB two@host",
]

[locale]
locales = ["en_GB.UTF-8", "en_US.UTF-8"]

[runcmd]
late_retries = 3
EOF
    toml_parse "$_tt_f" || no "parse returns success"

    assert_eq "scalar basic string" "$(toml_get system.hostname)" "mypi"
    assert_eq "scalar literal string" "$(toml_get user.name)" "alice"
    assert_eq "top-level key" "$(toml_get config_version)" "1.0"
    assert_ok "bool true resolves true" 'toml_bool ssh.enabled false'
    assert_fail "bool false resolves false" 'toml_bool user.password_encrypted true'
    assert_eq "int value" "$(toml_get runcmd.late_retries)" "3"

    assert_eq "multiline array count" "$(toml_array ssh.authorized_keys | wc -l | tr -d ' ')" "2"
    assert_contains "array elem 1" "$(toml_array ssh.authorized_keys)" "ssh-ed25519 AAAA one@host"
    assert_eq "single-line array count" "$(toml_array locale.locales | wc -l | tr -d ' ')" "2"

    assert_ok "present known key" 'toml_present system.hostname'
    assert_fail "absent key not present" 'toml_present system.nope'
    assert_contains "keys list includes section key" "$(toml_keys)" "ssh.enabled"

    toml_cleanup
    rm -f "$_tt_f"

    # i18n: UTF-8 values round-trip byte-exact; a leading BOM is tolerated.
    _tt_u=$(mktemp)
    printf '\357\273\277config_version = "1.0"\n[wlan]\nssid = "Caf\303\251_\346\227\245\346\234\254_\360\237\223\266"\n' >"$_tt_u"
    toml_parse "$_tt_u"
    assert_eq "BOM tolerated on first key" "$(toml_get config_version)" "1.0"
    assert_eq "utf-8 value round-trips byte-exact" "$(toml_get wlan.ssid)" "$(printf 'Caf\303\251_\346\227\245\346\234\254_\360\237\223\266')"
    toml_cleanup
    rm -f "$_tt_u"
}
