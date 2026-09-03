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

    # Brackets inside command strings must not terminate a multi-line array, or
    # every later element is dropped and re-read as a top-level line (#4).
    _tt_b=$(mktemp)
    cat >"$_tt_b" <<'EOF'
config_version = "1.0"

[runcmd]
late = [
  "some-command and its parameters",
  "sh -c 'if [ -d /path/to/some/dir ]; then a-conditional-command; fi'",
  'literal string with ] bracket',
  "trailing bracket ]",   # this ] is a comment holding "not-an-element"
  "yet another command and its parameters",
]
early = ["sh -c 'test [ -f /a ]'",
  "second element after a bracketed first",
]

[system]
hostname = "after-array"
EOF
    toml_parse "$_tt_b" || no "bracketed array parses"

    assert_eq "bracketed array keeps every element" \
        "$(toml_array runcmd.late | wc -l | tr -d ' ')" "5"
    assert_contains "element with brackets survives intact" "$(toml_array runcmd.late)" \
        "sh -c 'if [ -d /path/to/some/dir ]; then a-conditional-command; fi'"
    assert_contains "element after a bracketed one is not dropped" "$(toml_array runcmd.late)" \
        "yet another command and its parameters"
    assert_ncontains "comment text is not parsed as an element" \
        "$(toml_array runcmd.late)" "not-an-element"
    assert_eq "bracket on the opening line does not close the array" \
        "$(toml_array runcmd.early | wc -l | tr -d ' ')" "2"
    assert_eq "keys after a bracketed array still parse" "$(toml_get system.hostname)" "after-array"
    assert_fail "array elements do not leak in as keys" 'toml_present runcmd.late.fi'

    toml_cleanup
    rm -f "$_tt_b"

    # An array that never closes is still a hard error, not a silent truncation.
    _tt_x=$(mktemp)
    printf 'config_version = "1.0"\n[runcmd]\nlate = [\n  "sh -c '\''test ]'\''",\n' >"$_tt_x"
    if toml_parse "$_tt_x" 2>/dev/null; then
        no "unterminated array is a hard error"
    else
        ok "unterminated array is a hard error"
    fi
    toml_cleanup
    rm -f "$_tt_x"

    # Multi-line strings are outside the accepted subset. Parsing one used to
    # scatter it into stray fragments that runcmd would then execute, so the
    # whole file is now refused instead.
    _tt_m=$(mktemp)
    for _tt_q in '"""' "'''"; do
        cat >"$_tt_m" <<EOF
config_version = "1.0"
[runcmd]
late = [
  ${_tt_q}spans
lines${_tt_q},
  "after",
]
EOF
        if toml_parse "$_tt_m" 2>/dev/null; then
            no "multi-line string $_tt_q is a hard error"
        else
            ok "multi-line string $_tt_q is a hard error"
        fi
        toml_cleanup
    done

    # ...but a triple quote *inside* a string is ordinary text, not a delimiter.
    cat >"$_tt_m" <<'EOF'
config_version = "1.0"
[runcmd]
late = [
  'python3 -c """docstring"""',
  "python3 -c \"\"\"escaped\"\"\"",
  "",
  "after",
]
EOF
    toml_parse "$_tt_m" || no "quoted triple quotes still parse"
    assert_eq "quoted triple quotes are not a delimiter" \
        "$(toml_array runcmd.late | wc -l | tr -d ' ')" "4"
    assert_contains "triple quotes survive inside a literal string" \
        "$(toml_array runcmd.late)" 'python3 -c """docstring"""'
    assert_contains "escaped triple quotes survive in a basic string" \
        "$(toml_array runcmd.late)" 'python3 -c """escaped"""'
    toml_cleanup
    rm -f "$_tt_m"
}
