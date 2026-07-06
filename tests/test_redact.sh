# shellcheck shell=dash
# Redaction tests: secrets removed, PII tokenised (stable), patterns scrubbed.

t_redact() {
    _tr_f=$(mktemp)
    cat >"$_tr_f" <<'EOF'
config_version = "1.0"
[system]
hostname = "secrethost"
[user]
name = "alice"
password = "topsecretpw"
[wlan]
ssid = "MyHomeWifi"
password = "wifipass123"
[connect]
enabled = true
mode = "token"
token = "tok-abc-123"
EOF
    toml_parse "$_tr_f"
    redact_init

    _tr_secret=$(redact_line "the password is topsecretpw here")
    assert_ncontains "secret value removed" "$_tr_secret" "topsecretpw"
    assert_contains "secret placeholder present" "$_tr_secret" "***REDACTED***"

    _tr_tok=$(redact_line "connecting to wifipass123 token tok-abc-123")
    assert_ncontains "wlan password removed" "$_tr_tok" "wifipass123"
    assert_ncontains "connect token removed" "$_tr_tok" "tok-abc-123"

    _tr_pii=$(redact_line "host is secrethost and ssid MyHomeWifi user alice")
    assert_ncontains "hostname value not verbatim" "$_tr_pii" "secrethost"
    assert_ncontains "ssid value not verbatim" "$_tr_pii" "MyHomeWifi"
    assert_contains "hostname tokenised" "$_tr_pii" "<hostname:"
    assert_contains "ssid tokenised" "$_tr_pii" "<ssid:"

    # Stable tokenisation: same value -> same token across calls.
    _tr_a=$(redact_line "secrethost")
    _tr_b=$(redact_line "secrethost")
    assert_eq "pii token stable" "$_tr_a" "$_tr_b"

    # Generic pattern pass (independent of config values).
    _tr_pat=$(redact_line "mail a@b.com ip 10.1.2.3 mac de:ad:be:ef:00:11")
    assert_contains "email scrubbed" "$_tr_pat" "<email>"
    assert_contains "ip scrubbed" "$_tr_pat" "<ip>"
    assert_contains "mac scrubbed" "$_tr_pat" "<mac>"

    redact_cleanup
    toml_cleanup
    rm -f "$_tr_f"
}
