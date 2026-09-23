# shellcheck shell=dash
# shellcheck disable=SC2034  # path/stamp globals are consumed by other sourced modules
# rpi-preseed — common helpers, paths and state.
#
# Sourced by the main orchestrator and by the per-domain appliers. Defines the
# filesystem contract and small utilities shared across modules. No side effects
# on source beyond setting defaults.

# --- Path contract (all overridable for hermetic, unprivileged testing) --------

# Version / supported config schema (the main script may override these).
: "${RPI_PRESEED_VERSION:=0}"
: "${RPI_PRESEED_MAJOR:=1}"
: "${RPI_PRESEED_MINOR:=0}"

: "${RPI_PRESEED_ROOT:=}"
: "${RPI_PRESEED_STATE_DIR:=${RPI_PRESEED_ROOT}/var/lib/rpi-preseed}"
: "${RPI_PRESEED_BOOT_DIR:=${RPI_PRESEED_ROOT}/boot/firmware}"
: "${RPI_PRESEED_LEGACY_BOOT_DIR:=${RPI_PRESEED_ROOT}/boot}"

STATE_DIR="$RPI_PRESEED_STATE_DIR"
LOG_DIR="$STATE_DIR/log"
BREADCRUMB_DIR="$RPI_PRESEED_BOOT_DIR/rpi-preseed"
SALT_FILE="$STATE_DIR/redaction-salt"

# Per-phase success stamps and the fingerprinted failure stamp.
STAMP_APPLIED="$STATE_DIR/applied"
STAMP_EARLY="$STATE_DIR/early-runcmd-done"
STAMP_LATE="$STATE_DIR/runcmd-done"
STAMP_FAILED="$STATE_DIR/apply-failed"

# Default config location and its legacy fallback.
DEFAULT_CONFIG="$RPI_PRESEED_BOOT_DIR/rpi-preseed.toml"
LEGACY_CONFIG="$RPI_PRESEED_LEGACY_BOOT_DIR/rpi-preseed.toml"

# What a secret in the config source is replaced with once it has been applied.
REDACTED_SECRET='<redacted by rpi-preseed>'

# --- Small utilities -----------------------------------------------------------

# is_redacted VALUE — true if VALUE is a secret already consumed by an earlier
# apply. Applying it would overwrite the real secret with the marker.
is_redacted() {
    [ "$1" = "$REDACTED_SECRET" ]
}

# is_true VALUE — treat the common truthy spellings as true.
is_true() {
    case "$1" in
        true|True|TRUE|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ensure_dir DIR [MODE] — mkdir -p with an optional mode.
ensure_dir() {
    [ -d "$1" ] && return 0
    mkdir -p "$1" || return 1
    [ -n "${2:-}" ] && chmod "$2" "$1"
    return 0
}

# atomic_write PATH [MODE] — read stdin, write to PATH atomically (temp -> fsync
# -> mv). The rename is atomic on the same filesystem, so readers never see a
# partial file and an interrupted write leaves the previous contents intact.
#
# Permissions are settled on the temp file, before the rename, so the content is
# never briefly visible at the wrong mode. mktemp creates 0600 whatever the umask
# is and mv carries that onto the destination, so replacing a packaged file used
# to quietly lock out every reader but root -- which is how a rewritten
# /etc/default/keyboard stopped wayvnc starting (issue #5).
#
# MODE, when given, always wins: a caller writing a secret gets its 600 from the
# moment the file appears rather than a chmod afterwards, and one rewriting a
# file it owns outright repairs a mode an older version got wrong. Without MODE
# an existing destination keeps the mode and ownership it already had, which is
# what an applier editing someone else's file should do, and a new one lands 644.
# stat(1) rather than chmod --reference so this also holds under busybox.
atomic_write() {
    _aw_path="$1"
    _aw_mode="${2:-}"
    _aw_dir=$(dirname "$_aw_path")
    ensure_dir "$_aw_dir" || return 1
    _aw_tmp=$(mktemp "$_aw_dir/.tmp.XXXXXX") || return 1
    cat >"$_aw_tmp" || { rm -f "$_aw_tmp"; return 1; }
    if [ -n "$_aw_mode" ]; then
        chmod "$_aw_mode" "$_aw_tmp" 2>/dev/null || true
    elif [ -e "$_aw_path" ]; then
        _aw_keep=$(stat -c '%a' "$_aw_path" 2>/dev/null) || _aw_keep=
        [ -n "$_aw_keep" ] && { chmod "$_aw_keep" "$_aw_tmp" 2>/dev/null || true; }
        _aw_own=$(stat -c '%u:%g' "$_aw_path" 2>/dev/null) || _aw_own=
        [ -n "$_aw_own" ] && { chown "$_aw_own" "$_aw_tmp" 2>/dev/null || true; }
    else
        chmod 644 "$_aw_tmp" 2>/dev/null || true
    fi
    # Best-effort durability; sync(1) is always available even if fsync isn't.
    sync "$_aw_tmp" 2>/dev/null || sync
    mv -f "$_aw_tmp" "$_aw_path" || { rm -f "$_aw_tmp"; return 1; }
    return 0
}

# burn_rewrite PATH NEW — give PATH the contents of NEW, zeroing PATH's own
# blocks first. FAT overwrites in place, so this reaches the clusters that held
# the old contents; atomic_write's rename would free them with a secret intact.
burn_rewrite() {
    _br_size=$(wc -c <"$1") || return 1
    if [ "$_br_size" -gt 0 ]; then
        dd if=/dev/zero of="$1" bs="$_br_size" count=1 conv=notrunc,fsync \
            status=none || return 1
    fi
    cat "$2" >"$1" || return 1
    sync "$1" 2>/dev/null || sync
}

# user_ids USER — "uid:gid" for USER on the target, empty when not found.
user_ids() {
    if [ -z "$RPI_PRESEED_ROOT" ]; then
        getent passwd "$1" 2>/dev/null | awk -F: '{print $3":"$4; exit}'
    else
        awk -F: -v u="$1" '$1==u {print $3":"$4; exit}' \
            "$(target_path /etc/passwd)" 2>/dev/null
    fi
}

# user_home USER — home directory for USER on the target, empty when not found.
user_home() {
    if [ -z "$RPI_PRESEED_ROOT" ]; then
        getent passwd "$1" 2>/dev/null | cut -d: -f6
    else
        awk -F: -v u="$1" '$1==u {print $6; exit}' \
            "$(target_path /etc/passwd)" 2>/dev/null
    fi
}

# own_user_path USER PATH... — give PATHs to USER.
#
# Anything an applier writes is created by root: mkdir in ensure_dir and
# mktemp + mv in atomic_write both leave root as the owner. Under a user's home
# that is wrong, and silently so -- a root-owned file at mode 600 cannot be read
# by the account it was written for, which is exactly the account a systemd
# *user* unit runs as.
#
# Resolved numerically from the target's own passwd so this is also correct when
# applying to a mounted image: chowning by name would resolve against the host's
# passwd, which is a different machine's idea of who that user is. Missing paths
# are skipped and a failed chown is not fatal -- ownership is a correctness
# improvement on a best-effort applier, never a reason to abort one.
own_user_path() {
    _oup_user=$1
    shift
    [ -n "$_oup_user" ] || return 0
    _oup_ids=$(user_ids "$_oup_user")
    [ -n "$_oup_ids" ] || return 0
    for _oup_p in "$@"; do
        [ -e "$_oup_p" ] || [ -L "$_oup_p" ] || continue
        # -h so a symlink is retargeted rather than followed: the enablement
        # links point at unit files under /usr/lib, which are not ours to give
        # away. Harmless on everything that is not a symlink.
        chown -h "$_oup_ids" "$_oup_p" 2>/dev/null || true
    done
    return 0
}

# write_stamp PATH — record a success stamp carrying provenance.
write_stamp() {
    _ws_path="$1"
    printf 'timestamp=%s\nversion=%s\nfingerprint=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
        "${RPI_PRESEED_VERSION:-0}" \
        "${CONFIG_FINGERPRINT:-none}" | atomic_write "$_ws_path"
}

# stamp_fingerprint PATH — print the fingerprint recorded in a stamp (if any).
stamp_fingerprint() {
    [ -f "$1" ] || return 1
    sed -n 's/^fingerprint=//p' "$1" | head -n1
}

# config_fingerprint FILE — stable sha256 of the config contents.
config_fingerprint() {
    [ -f "$1" ] || { echo none; return 1; }
    sha256sum "$1" | cut -d' ' -f1
}

# have CMD — is CMD available on PATH?
have() {
    command -v "$1" >/dev/null 2>&1
}

# --- Reused Raspberry Pi helper locations (overridable) ------------------------
: "${IMAGER_CUSTOM:=/usr/lib/raspberrypi-sys-mods/imager_custom}"
: "${USERCONF:=/usr/lib/userconf-pi/userconf}"
: "${RASPI_CONFIG:=raspi-config}"

# helpers_live — true when we should drive the real on-device helpers (running on
# the actual system as root), rather than the sandbox file-based fallbacks.
helpers_live() {
    [ -z "$RPI_PRESEED_ROOT" ] && [ "$(id -u 2>/dev/null || echo 1)" = 0 ]
}

# imager_available — true when the RPi imager_custom helper should drive changes.
imager_available() {
    helpers_live && [ -x "$IMAGER_CUSTOM" ]
}

# first_user — login name of UID 1000 on the target (best effort).
first_user() {
    if [ -z "$RPI_PRESEED_ROOT" ]; then
        getent passwd 1000 2>/dev/null | cut -d: -f1
    else
        awk -F: '$3==1000 {print $1; exit}' "$(target_path /etc/passwd)" 2>/dev/null
    fi
}

# first_user_home — home directory of UID 1000 on the target (best effort).
first_user_home() {
    if [ -z "$RPI_PRESEED_ROOT" ]; then
        getent passwd 1000 2>/dev/null | cut -d: -f6
    else
        awk -F: '$3==1000 {print $6; exit}' "$(target_path /etc/passwd)" 2>/dev/null
    fi
}

# report_run KEY SOURCE CMD... — run CMD; record applied/failed for KEY.
report_run() {
    _rr_key=$1; _rr_src=$2; shift 2
    if "$@"; then
        report_key "$_rr_key" applied "$_rr_src"
    else
        report_key "$_rr_key" failed "$_rr_src"
        return 1
    fi
}

# _crypt_method_available METHOD — does mkpasswd advertise crypt METHOD?
_crypt_method_available() {
    mkpasswd -m help 2>/dev/null | grep -qiw -- "$1"
}

# hash_password PLAINTEXT — print a crypt(3) hash for chpasswd -e / usermod -p.
# Prefers yescrypt (the Raspberry Pi OS / Debian default via libxcrypt). Only
# downgrades to the older sha512crypt scheme if yescrypt is unavailable, and logs
# loudly when it does so the weaker hash is never silent.
hash_password() {
    if have mkpasswd; then
        if _crypt_method_available yescrypt; then
            mkpasswd -m yescrypt "$1" 2>/dev/null && return 0
        fi
        for _hp_m in sha512crypt sha-512; do
            if _crypt_method_available "$_hp_m"; then
                log_warn "password: yescrypt unavailable; using weaker $_hp_m"
                mkpasswd -m "$_hp_m" "$1" 2>/dev/null && return 0
            fi
        done
    fi
    if have openssl; then
        log_warn "password: yescrypt/mkpasswd unavailable; using weaker openssl sha512crypt"
        openssl passwd -6 "$1" 2>/dev/null && return 0
    fi
    log_error "password: no usable crypt tool; install 'whois' for mkpasswd yescrypt"
    return 1
}

# in_chroot_root PATH... — prefix a target path with RPI_PRESEED_ROOT.
# Appliers write through this so tests can target a sandbox rootfs.
target_path() {
    printf '%s%s' "$RPI_PRESEED_ROOT" "$1"
}

# hex_to_nm_bytes HEX — convert a hex-encoded SSID to a NetworkManager keyfile
# byte-array ("b1;b2;...;", decimal octets). Used for exotic, non-UTF-8 SSIDs
# that cannot be represented as a UTF-8 TOML/keyfile string. Returns non-zero on
# empty, odd-length or non-hex input.
hex_to_nm_bytes() {
    _hnb_h=$1
    case "$_hnb_h" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
    [ $(( ${#_hnb_h} % 2 )) -eq 0 ] || return 1
    _hnb_out=""
    while [ -n "$_hnb_h" ]; do
        _hnb_pair=${_hnb_h%"${_hnb_h#??}"}   # leading two hex digits
        _hnb_h=${_hnb_h#??}                  # remaining digits
        _hnb_out="${_hnb_out}$(printf '%d' "0x$_hnb_pair");"
    done
    printf '%s' "$_hnb_out"
}
