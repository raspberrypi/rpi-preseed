# shellcheck shell=dash
# rpi-preseed — minimal, safe TOML parser (POSIX sh).
#
# Supports the subset rpi-preseed uses: [sections], scalar strings (basic "" and
# literal ''), booleans, non-negative integers, and arrays of strings (single- or
# multi-line). Values are never eval'd; parsed data is written to a private store
# file and retrieved through accessor functions that emit safely-quoted values.
#
# Store record format (US = 0x1f field separator):
#   s<US>dotted.key<US>value      scalar
#   a<US>dotted.key<US>value      array element (in order; one record per element)

US=$(printf '\037')
CR=$(printf '\r')
BOM=$(printf '\357\273\277')   # UTF-8 byte-order mark (some editors prepend it)

# _trim STRING — strip leading/trailing whitespace.
_trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# _unescape_basic STRING — unescape the handful of basic-string escapes we accept.
# \\ and \" only, to keep parsed values single-line and store-safe.
_unescape_basic() {
    printf '%s' "$1" | sed -e 's/\\\\/\a/g' -e 's/\\"/"/g' -e 's/\a/\\/g'
}

# _toml_scan TEXT — walk TEXT once, honouring TOML string and comment rules, and
# print one record per token we care about, in order:
#   B<value>   basic string literal (escapes left intact for _unescape_basic)
#   L<value>   literal string (no unescape)
#   ]          the bracket that closes the array TEXT opens
#   M          a multi-line string delimiter (""" or '''), which we reject
# Scanning stops at either of the last two. Only unquoted, uncommented brackets
# count, so an element such as "sh -c 'if [ -d /x ]; then y; fi'" neither ends
# the array early nor gets split, and a '#' comment cannot smuggle in an extra
# element. Strings never span lines in the subset we accept, so each line is
# scanned on its own — an unterminated quote can only spoil its own line.
_toml_scan() {
    awk '
    {
        n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (c == "\"") {
                if (substr($0, i, 3) == "\"\"\"") { print "M"; exit }
                i++; val = ""
                while (i <= n) {
                    c = substr($0, i, 1)
                    if (c == "\\") { val = val substr($0, i, 2); i += 2; continue }
                    if (c == "\"") break
                    val = val c; i++
                }
                print "B" val
            } else if (c == "\x27") {   # single quote: literal string, no unescape
                if (substr($0, i, 3) == "\x27\x27\x27") { print "M"; exit }
                i++; val = ""
                while (i <= n) {
                    c = substr($0, i, 1)
                    if (c == "\x27") break
                    val = val c; i++
                }
                print "L" val
            } else if (c == "#") {
                next                    # comment runs to end of line
            } else if (c == "[") {
                depth++
            } else if (c == "]") {
                depth--
                if (depth <= 0) { print "]"; exit }
            }
        }
    }'
}

# _toml_array_closed TEXT — succeed once TEXT holds the ']' closing the array it
# opens. Callers use this instead of grepping for a bare ']' so that brackets
# inside command strings do not truncate the array (raspberrypi/rpi-preseed#4).
_toml_array_closed() {
    printf '%s\n' "$1" | _toml_scan | grep -q '^]$'
}

# _toml_opens_multiline TEXT — succeed if TEXT opens a multi-line string. Asking
# the scanner rather than matching """ textually keeps a quoted occurrence — say
# 'python3 -c """doc"""' — from being mistaken for a delimiter.
_toml_opens_multiline() {
    printf '%s\n' "$1" | _toml_scan | grep -q '^M$'
}

# toml_parse FILE — parse into a fresh store. Returns non-zero on a hard error.
toml_parse() {
    _tp_file="$1"
    [ -f "$_tp_file" ] || { echo "toml: no such file: $_tp_file" >&2; return 1; }
    TOML_STORE=$(mktemp) || return 1
    : >"$TOML_STORE"

    _tp_section=""
    _tp_collect=""      # non-empty while accumulating a multi-line array
    _tp_arrkey=""
    _tp_arrbuf=""
    _tp_first=1

    while IFS= read -r _tp_raw || [ -n "$_tp_raw" ]; do
        _tp_raw=${_tp_raw%"$CR"}
        if [ "$_tp_first" = 1 ]; then
            _tp_raw=${_tp_raw#"$BOM"}   # tolerate a UTF-8 BOM on the first line
            _tp_first=0
        fi

        # We accept only single-line strings. Silently mangling a multi-line one
        # into stray fragments would hand runcmd garbage to execute, so refuse
        # the file outright. The glob is a cheap gate on the scanner.
        case "$_tp_raw" in
            *'"""'*|*"'''"*)
                if _toml_opens_multiline "$_tp_raw"; then
                    echo "toml: multi-line strings are not supported; keep the value on one line: $(_trim "$_tp_raw")" >&2
                    return 1
                fi ;;
        esac

        if [ -n "$_tp_collect" ]; then
            _tp_arrbuf="$_tp_arrbuf
$_tp_raw"
            # A ']' on this line is only a candidate terminator; re-scan the
            # whole buffer to see whether it really closes the array.
            case "$_tp_raw" in
                *']'*)
                    if _toml_array_closed "$_tp_arrbuf"; then
                        _toml_flush_array "$_tp_arrkey" "$_tp_arrbuf"
                        _tp_collect=""; _tp_arrkey=""; _tp_arrbuf=""
                    fi ;;
            esac
            continue
        fi

        _tp_line=$(_trim "$_tp_raw")
        case "$_tp_line" in
            ''|'#'*) continue ;;
        esac

        # Section header: [name]
        case "$_tp_line" in
            '['*']')
                _tp_section=$(printf '%s' "$_tp_line" | sed 's/^\[[[:space:]]*//; s/[[:space:]]*\]$//')
                continue ;;
        esac

        # key = value
        case "$_tp_line" in
            *=*) : ;;
            *) echo "toml: ignoring malformed line: $_tp_line" >&2; continue ;;
        esac
        _tp_key=$(_trim "${_tp_line%%=*}")
        _tp_val=$(_trim "${_tp_line#*=}")
        # Strip surrounding quotes on keys if present.
        _tp_key=$(printf '%s' "$_tp_key" | sed 's/^"\(.*\)"$/\1/; s/^'\''\(.*\)'\''$/\1/')
        if [ -n "$_tp_section" ]; then
            _tp_fqk="$_tp_section.$_tp_key"
        else
            _tp_fqk="$_tp_key"
        fi

        case "$_tp_val" in
            '['*)
                if _toml_array_closed "$_tp_val"; then
                    _toml_flush_array "$_tp_fqk" "$_tp_val"
                else
                    _tp_collect=1; _tp_arrkey="$_tp_fqk"; _tp_arrbuf="$_tp_val"
                fi ;;
            '"'*)
                _tp_s=$(_toml_scalar_string "$_tp_val" '"')
                _toml_put s "$_tp_fqk" "$_tp_s" ;;
            "'"*)
                _tp_s=$(_toml_scalar_string "$_tp_val" "'")
                _toml_put s "$_tp_fqk" "$_tp_s" ;;
            *)
                # Bare token: bool / int. Drop any inline comment.
                _tp_s=$(printf '%s' "$_tp_val" | sed 's/[[:space:]]*#.*$//' )
                _tp_s=$(_trim "$_tp_s")
                _toml_put s "$_tp_fqk" "$_tp_s" ;;
        esac
    done <"$_tp_file"

    if [ -n "$_tp_collect" ]; then
        echo "toml: unterminated array for key: $_tp_arrkey" >&2
        return 1
    fi
    return 0
}

# _toml_scalar_string RHS QUOTECHAR — extract a single quoted string value,
# discarding any trailing inline comment.
_toml_scalar_string() {
    _tss_first=$(printf '%s\n' "$1" | _toml_scan | head -n1)
    case "$_tss_first" in
        B*) _unescape_basic "${_tss_first#B}" ;;
        L*) printf '%s' "${_tss_first#L}" ;;
        *)  printf '%s' "" ;;
    esac
}

# _toml_flush_array KEY RAW — parse array literals out of RAW and store them.
# The ']' record _toml_scan ends on is not an element, so it falls through.
_toml_flush_array() {
    _tfa_key="$1"
    printf '%s\n' "$2" | _toml_scan | while IFS= read -r _tfa_e; do
        case "$_tfa_e" in
            B*) _toml_put a "$_tfa_key" "$(_unescape_basic "${_tfa_e#B}")" ;;
            L*) _toml_put a "$_tfa_key" "${_tfa_e#L}" ;;
        esac
    done
}

# _toml_put TYPE KEY VALUE — append a record to the store.
_toml_put() {
    printf '%s%s%s%s%s\n' "$1" "$US" "$2" "$US" "$3" >>"$TOML_STORE"
}

# toml_get KEY — print the scalar value for KEY. Returns 1 if absent.
toml_get() {
    awk -F"$US" -v k="$1" '$1=="s" && $2==k {print $3; f=1} END{exit !f}' "$TOML_STORE"
}

# toml_get_default KEY DEFAULT — print scalar value or DEFAULT.
toml_get_default() {
    if _tgd=$(toml_get "$1"); then printf '%s' "$_tgd"; else printf '%s' "$2"; fi
}

# toml_bool KEY DEFAULT — resolve a boolean; returns 0 (true) / 1 (false).
toml_bool() {
    _tb=$(toml_get_default "$1" "$2")
    is_true "$_tb"
}

# toml_array KEY — print array elements, one per line.
toml_array() {
    awk -F"$US" -v k="$1" '$1=="a" && $2==k {print $3}' "$TOML_STORE"
}

# toml_values KEY — print every value for KEY, scalar or array, one per line.
toml_values() {
    awk -F"$US" -v k="$1" '($1=="s" || $1=="a") && $2==k {print $3}' "$TOML_STORE"
}

# toml_present KEY — succeed if KEY has any record.
toml_present() {
    awk -F"$US" -v k="$1" '$2==k {f=1} END{exit !f}' "$TOML_STORE"
}

# toml_keys — print every distinct key present in the store.
toml_keys() {
    awk -F"$US" '{print $2}' "$TOML_STORE" | sort -u
}

# toml_cleanup — remove the store file.
toml_cleanup() {
    [ -n "${TOML_STORE:-}" ] && rm -f "$TOML_STORE"
    TOML_STORE=""
}
