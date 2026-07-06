# shellcheck shell=dash
# rpi-preseed — redaction of secrets and PII across all log/report/bundle sinks.
#
# See DESIGN.md 12.6. Secrets are removed entirely; PII is replaced with a stable
# per-device salted-hash token so logs stay correlatable without exposing values;
# 'plain' values are kept. A generic pattern pass covers arbitrary runcmd text.

REDACT_SECRET_TOKEN='***REDACTED***'

# redact_salt — print the per-device salt, generating it (600) on first use.
redact_salt() {
    if [ ! -f "$SALT_FILE" ]; then
        ensure_dir "$STATE_DIR" 755 || return 1
        head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$SALT_FILE"
        chmod 600 "$SALT_FILE" 2>/dev/null || true
    fi
    cat "$SALT_FILE"
}

# _redact_hash STRING — short salted digest of STRING.
_redact_hash() {
    printf '%s%s' "$(redact_salt)" "$1" | sha256sum | cut -c1-8
}

# _redact_token KEY VALUE — PII placeholder like <hostname:1a2b3c4d>.
_redact_token() {
    _rt_leaf=${1##*.}
    printf '<%s:%s>' "$_rt_leaf" "$(_redact_hash "$2")"
}

# redact_init — build the value->replacement table from the parsed config.
# Longest values first so a value that is a substring of another cannot leak.
redact_init() {
    REDACT_PAIRS=$(mktemp) || return 1
    : >"$REDACT_PAIRS"
    for _ri_key in $(toml_keys); do
        case "$(schema_class "$_ri_key" 2>/dev/null)" in
            secret) _ri_repl="$REDACT_SECRET_TOKEN" ;;
            pii)    _ri_repl="" ;;   # per-value token computed below
            *)      continue ;;
        esac
        toml_values "$_ri_key" | while IFS= read -r _ri_v; do
            [ -n "$_ri_v" ] || continue
            _ri_t=${_ri_repl:-$(_redact_token "$_ri_key" "$_ri_v")}
            printf '%s%s%s\n' "$_ri_v" "$US" "$_ri_t" >>"$REDACT_PAIRS"
        done
    done
    # Sort by descending value length.
    if [ -s "$REDACT_PAIRS" ]; then
        _ri_sorted=$(mktemp)
        awk -F"$US" '{print length($1) "\t" $0}' "$REDACT_PAIRS" \
            | sort -rn | cut -f2- >"$_ri_sorted"
        mv -f "$_ri_sorted" "$REDACT_PAIRS"
    fi
}

# _redact_patterns — generic pass over stdin for arbitrary text (runcmd etc.).
_redact_patterns() {
    sed -E \
        -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
        -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://[^/@[:space:]]+):[^@[:space:]]+@#\1:<secret>@#g' \
        -e 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<mac>/g' \
        -e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/<ip>/g'
}

# redact_stream — filter stdin to stdout applying value table + pattern pass.
redact_stream() {
    if [ -n "${REDACT_PAIRS:-}" ] && [ -s "$REDACT_PAIRS" ]; then
        awk -v pairs="$REDACT_PAIRS" -v us="$US" '
        BEGIN {
            FS = us
            while ((getline line < pairs) > 0) {
                p = index(line, us)
                if (p > 0) {
                    v = substr(line, 1, p - 1)
                    t = substr(line, p + 1)
                    n++; find[n] = v; repl[n] = t
                }
            }
        }
        {
            s = $0
            for (i = 1; i <= n; i++) {
                if (find[i] == "") continue
                out = ""; rest = s
                while ((pos = index(rest, find[i])) > 0) {
                    out = out substr(rest, 1, pos - 1) repl[i]
                    rest = substr(rest, pos + length(find[i]))
                }
                s = out rest
            }
            print s
        }' | _redact_patterns
    else
        _redact_patterns
    fi
}

# redact_line STRING — redact a single string, print result.
redact_line() {
    printf '%s\n' "$1" | redact_stream
}

# redact_cleanup — remove the pairs table.
redact_cleanup() {
    [ -n "${REDACT_PAIRS:-}" ] && rm -f "$REDACT_PAIRS"
    REDACT_PAIRS=""
}
