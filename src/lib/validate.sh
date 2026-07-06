# shellcheck shell=dash
# rpi-preseed — schema loading + configuration validation.
#
# Strict on known keys (type/enum/required -> hard fail); lenient on unknown keys
# and sections (warn once and skip) for forward compatibility. Also owns the
# schema-lookup helpers used by the redactor.

: "${RPI_PRESEED_SCHEMA:=}"

# schema_file — resolve the schema table path (env override, install, or repo).
schema_file() {
    if [ -n "$RPI_PRESEED_SCHEMA" ]; then printf '%s' "$RPI_PRESEED_SCHEMA"; return; fi
    for _sf in /usr/share/rpi-preseed/rpi-preseed.schema \
               "${RPI_PRESEED_BASEDIR:-.}/../schema/rpi-preseed.schema" \
               "${RPI_PRESEED_BASEDIR:-.}/schema/rpi-preseed.schema"; do
        [ -f "$_sf" ] && { printf '%s' "$_sf"; return; }
    done
    printf '%s' /usr/share/rpi-preseed/rpi-preseed.schema
}

# schema_lookup KEY — print "type class flags" for KEY; return 1 if unknown.
schema_lookup() {
    awk -v k="$1" '!/^#/ && NF>=3 && $1==k {print $2, $3, $4; f=1; exit} END{exit !f}' \
        "$(schema_file)"
}

schema_type()  { schema_lookup "$1" | awk '{print $1}'; }
schema_class() { schema_lookup "$1" | awk '{print $2}'; }
schema_known() { schema_lookup "$1" >/dev/null 2>&1; }

# schema_required_keys — print all keys flagged 'required'.
schema_required_keys() {
    awk '!/^#/ && NF>=4 && $4=="required" {print $1}' "$(schema_file)"
}

# _validate_type TYPE VALUE — succeed if VALUE matches TYPE.
_validate_type() {
    case "$1" in
        string) return 0 ;;
        bool)
            case "$2" in true|false) return 0 ;; *) return 1 ;; esac ;;
        int)
            case "$2" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac ;;
        array) return 0 ;;
        enum:*)
            _vt_allowed=${1#enum:}
            _vt_oldifs=$IFS; IFS=,
            for _vt_a in $_vt_allowed; do
                [ "$_vt_a" = "$2" ] && { IFS=$_vt_oldifs; return 0; }
            done
            IFS=$_vt_oldifs; return 1 ;;
        *) return 0 ;;
    esac
}

# validate_config — validate the parsed store. Prints problems; returns non-zero
# if any hard error was found. Requires toml_parse to have populated the store.
validate_config() {
    _vc_errors=0

    # Required keys present?
    for _vc_req in $(schema_required_keys); do
        if ! toml_present "$_vc_req"; then
            log_error "config: required key missing: $_vc_req"
            _vc_errors=$((_vc_errors + 1))
        fi
    done

    # Each present key: known -> strict; unknown -> warn + skip.
    for _vc_key in $(toml_keys); do
        if ! schema_known "$_vc_key"; then
            log_warn "config: unknown key ignored: $_vc_key"
            continue
        fi
        _vc_type=$(schema_type "$_vc_key")
        case "$_vc_type" in
            array)
                # Validate nothing element-wise beyond presence for arrays.
                : ;;
            *)
                _vc_val=$(toml_get "$_vc_key" 2>/dev/null || printf '')
                if ! _validate_type "$_vc_type" "$_vc_val"; then
                    log_error "config: key '$_vc_key' has invalid value for type $_vc_type: '$_vc_val'"
                    _vc_errors=$((_vc_errors + 1))
                fi ;;
        esac
    done

    # Cross-field required combinations.
    _validate_combos || _vc_errors=$((_vc_errors + 1))

    [ "$_vc_errors" -eq 0 ]
}

# _validate_combos — required-combination rules that span keys.
_validate_combos() {
    _vco_ok=0

    # connect.token required iff connect.mode == token.
    if toml_present connect.mode; then
        _vco_mode=$(toml_get connect.mode)
        if [ "$_vco_mode" = token ] && ! toml_present connect.token; then
            log_error "config: connect.mode='token' requires connect.token"
            _vco_ok=1
        fi
        if [ "$_vco_mode" = device-identity ] && toml_present connect.token; then
            log_error "config: connect.token must not be set when connect.mode='device-identity'"
            _vco_ok=1
        fi
    fi

    # user.password requires user.name.
    if toml_present user.password && ! toml_present user.name; then
        log_error "config: user.password requires user.name"
        _vco_ok=1
    fi

    # hostname must be a valid RFC 1123 name; Wi-Fi settings must be consistent.
    if toml_present system.hostname; then
        _validate_hostname || _vco_ok=1
    fi
    _validate_wlan || _vco_ok=1

    # locale.lang / lc_* should be members of locale.locales (if locales given).
    if toml_present locale.locales; then
        for _vco_k in locale.lang locale.lc_time locale.lc_measurement; do
            if toml_present "$_vco_k"; then
                _vco_v=$(toml_get "$_vco_k")
                if ! toml_array locale.locales | grep -qxF "$_vco_v"; then
                    log_warn "config: $_vco_k='$_vco_v' is not listed in locale.locales"
                fi
            fi
        done
    fi

    return "$_vco_ok"
}

# _validate_hostname — RFC 1123: ASCII letter/digit/hyphen labels, each 1-63 and
# not starting/ending with a hyphen, total <= 253. (Hostnames are ASCII by design;
# internationalised names would need IDNA/punycode, which we do not do.)
_validate_hostname() {
    _vh=$(toml_get system.hostname)
    if [ "${#_vh}" -gt 253 ]; then
        log_error "config: system.hostname is too long (max 253 characters)"
        return 1
    fi
    if ! printf '%s' "$_vh" | LC_ALL=C grep -Eq \
        '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'; then
        log_error "config: system.hostname is not a valid RFC 1123 hostname (ASCII letters, digits and hyphens; each label 1-63 chars; no leading/trailing hyphen)"
        return 1
    fi
    return 0
}

# wlan_key_mgmt — effective Wi-Fi key management: explicit wlan.key_mgmt, else
# wpa-psk when a password is given, else none (open network).
wlan_key_mgmt() {
    if toml_present wlan.key_mgmt; then
        toml_get wlan.key_mgmt
    elif toml_present wlan.password; then
        echo wpa-psk
    else
        echo none
    fi
}

# _validate_wlan — Wi-Fi consistency + passphrase rules. Open networks
# (none/owe) must have no password; wpa-psk/sae require one. The passphrase is
# validated by OCTET length so UTF-8 is allowed: wpa-psk is 8-63 octets (or a raw
# 64-hex-char PMK); sae only needs to be non-empty. Encrypted PSKs pass through.
_validate_wlan() {
    toml_present wlan.ssid || return 0
    _vw_km=$(wlan_key_mgmt)

    case "$_vw_km" in
        none|owe)
            if toml_present wlan.password; then
                log_error "config: wlan.password must not be set for an open network (key_mgmt=$_vw_km)"
                return 1
            fi
            return 0 ;;
    esac

    if ! toml_present wlan.password; then
        log_error "config: wlan.password is required for key_mgmt=$_vw_km"
        return 1
    fi
    toml_bool wlan.password_encrypted false && return 0
    _vw_pass=$(toml_get wlan.password)
    _vw_len=$(printf '%s' "$_vw_pass" | LC_ALL=C wc -c | tr -d ' ')

    # A 64-hex-digit value is a raw 256-bit PMK, valid for any scheme.
    if [ "$_vw_len" -eq 64 ] && printf '%s' "$_vw_pass" | LC_ALL=C grep -Eq '^[0-9A-Fa-f]{64}$'; then
        return 0
    fi
    case "$_vw_km" in
        wpa-psk)
            if [ "$_vw_len" -lt 8 ] || [ "$_vw_len" -gt 63 ]; then
                log_error "config: wlan.password must be 8-63 octets for wpa-psk (got $_vw_len); use key_mgmt='sae' for a longer WPA3 passphrase"
                return 1
            fi ;;
        sae)
            if [ "$_vw_len" -lt 1 ]; then
                log_error "config: wlan.password must not be empty"
                return 1
            fi ;;
    esac
    return 0
}

# validate_version — enforce the config_version compatibility policy.
# Returns 0 to proceed, 1 to refuse.
validate_version() {
    _vv_raw=$(toml_get_default config_version "1.0")
    case "$_vv_raw" in
        [0-9]) _vv_raw="$_vv_raw.0" ;;
    esac
    _vv_major=${_vv_raw%%.*}
    _vv_minor=${_vv_raw#*.}
    case "$_vv_major$_vv_minor" in
        *[!0-9]*) log_error "config: malformed config_version: $_vv_raw"; return 1 ;;
    esac
    if [ "$_vv_major" != "$RPI_PRESEED_MAJOR" ]; then
        log_error "config: config_version major $_vv_major unsupported (this tool supports major $RPI_PRESEED_MAJOR)"
        return 1
    fi
    if [ "$_vv_minor" -gt "$RPI_PRESEED_MINOR" ]; then
        log_warn "config: declares 1.$_vv_minor but this tool supports up to 1.$RPI_PRESEED_MINOR; some settings may be ignored — update rpi-preseed"
    fi
    return 0
}
