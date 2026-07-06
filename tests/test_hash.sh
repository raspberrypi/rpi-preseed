# shellcheck shell=dash
# shellcheck disable=SC2016  # '$y$'/'$6$' are intentional literals; assert_ok bodies defer expansion.
# Password hashing: prefer yescrypt, never silently emit a weak scheme.

t_hash() {
    if command -v mkpasswd >/dev/null 2>&1 && mkpasswd -m help 2>/dev/null | grep -qiw yescrypt; then
        _th=$(hash_password "hunter2")
        case "$_th" in
            '$y$'*) ok "hash_password prefers yescrypt" ;;
            '$6$'*) no "hash_password fell back to sha512crypt despite yescrypt support" ;;
            *)      no "hash_password produced an unexpected scheme" ;;
        esac
    else
        ok "yescrypt preference test skipped (mkpasswd/yescrypt unavailable here)"
    fi

    if command -v mkpasswd >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1; then
        assert_ok "hash_password produces a non-empty hash" '[ -n "$(hash_password pw)" ]'
    fi
}
