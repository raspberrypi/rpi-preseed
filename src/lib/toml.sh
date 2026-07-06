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

# _emit_quoted_literals TEXT — print every quoted string literal found in TEXT,
# one per line, in order. Used for array elements; ignores commas, comments,
# whitespace and newlines between literals (all our arrays are arrays of strings).
_emit_quoted_literals() {
    awk '
    {
        line = line sep $0; sep = "\n"
    }
    END {
        n = length(line)
        i = 1
        while (i <= n) {
            c = substr(line, i, 1)
            if (c == "\"") {
                i++; val = ""
                while (i <= n) {
                    c = substr(line, i, 1)
                    if (c == "\\") { val = val substr(line, i, 2); i += 2; continue }
                    if (c == "\"") { i++; break }
                    val = val c; i++
                }
                print "B" val
            } else if (c == "\x27") {   # single quote: literal string, no unescape
                i++; val = ""
                while (i <= n) {
                    c = substr(line, i, 1)
                    if (c == "\x27") { i++; break }
                    val = val c; i++
                }
                print "L" val
            } else {
                i++
            }
        }
    }'
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

        if [ -n "$_tp_collect" ]; then
            _tp_arrbuf="$_tp_arrbuf
$_tp_raw"
            case "$_tp_raw" in
                *']'*) _toml_flush_array "$_tp_arrkey" "$_tp_arrbuf"
                       _tp_collect=""; _tp_arrkey=""; _tp_arrbuf="" ;;
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
                case "$_tp_val" in
                    *']'*) _toml_flush_array "$_tp_fqk" "$_tp_val" ;;
                    *) _tp_collect=1; _tp_arrkey="$_tp_fqk"; _tp_arrbuf="$_tp_val" ;;
                esac ;;
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
    _tss_first=$(printf '%s\n' "$1" | _emit_quoted_literals | head -n1)
    case "$_tss_first" in
        B*) _unescape_basic "${_tss_first#B}" ;;
        L*) printf '%s' "${_tss_first#L}" ;;
        *)  printf '%s' "" ;;
    esac
}

# _toml_flush_array KEY RAW — parse array literals out of RAW and store them.
_toml_flush_array() {
    _tfa_key="$1"
    printf '%s\n' "$2" | _emit_quoted_literals | while IFS= read -r _tfa_e; do
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
