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
: "${RPI_PRESEED_PERSIST_DIR:=${RPI_PRESEED_ROOT}/persistent}"
: "${RPI_PRESEED_BOOTFS_DIR:=${RPI_PRESEED_ROOT}/bootfs}"

STATE_DIR="$RPI_PRESEED_STATE_DIR"
LOG_DIR="$STATE_DIR/log"
BREADCRUMB_DIR="$RPI_PRESEED_BOOT_DIR/rpi-preseed"
SALT_FILE="$STATE_DIR/redaction-salt"

# Per-phase success stamps and the fingerprinted failure stamp.
STAMP_APPLIED="$STATE_DIR/applied"
STAMP_EARLY="$STATE_DIR/early-runcmd-done"
STAMP_LATE="$STATE_DIR/runcmd-done"
STAMP_FAILED="$STATE_DIR/apply-failed"

# Config locations. An immutable image's boot partition is read-only and the
# same on every device, so a per-device config goes on its persistent
# partition, at the root because fastbootd cannot create directories, or on
# its writable /bootfs, the first partition, where Imager writes.
PERSIST_CONFIG="$RPI_PRESEED_PERSIST_DIR/rpi-preseed.toml"
BOOTFS_CONFIG="$RPI_PRESEED_BOOTFS_DIR/rpi-preseed.toml"
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
        _target_passwd_entry "$1" | awk -F: '{print $3":"$4; exit}'
    fi
}

# user_home USER — home directory for USER on the target, empty when not found.
user_home() {
    if [ -z "$RPI_PRESEED_ROOT" ]; then
        getent passwd "$1" 2>/dev/null | cut -d: -f6
    else
        _target_passwd_entry "$1" | cut -d: -f6
    fi
}

# _target_passwd_entry USER — USER's passwd line on a mounted target. A live
# system's NSS already covers userdb; a mounted one reads the records
# rpi-preseed writes, which keep uid, gid and homeDirectory in that order.
_target_passwd_entry() {
    awk -F: -v u="$1" '$1==u {print; f=1; exit} END{exit !f}' \
        "$(target_path /etc/passwd)" 2>/dev/null && return 0
    _tpe_rec="$(target_path /etc/userdb)/$1.user"
    [ -f "$_tpe_rec" ] || return 1
    sed -n 's/.*"uid":\([0-9]*\).*"gid":\([0-9]*\).*"homeDirectory":"\([^"]*\)".*/\1:\2:\3/p' \
        "$_tpe_rec" | awk -F: -v u="$1" '{print u":x:"$1":"$2"::"$3":"; exit}'
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

# writable_dir DIR — can a file be created in DIR? Probed rather than tested
# with -w, which busybox answers yes to on a read-only mount when run as root.
writable_dir() {
    _wd_probe=$(mktemp "$1/.rpi-preseed-probe.XXXXXX" 2>/dev/null) || return 1
    rm -f "$_wd_probe"
}

# What this image can keep, written by its build: one entry per line, either
#   <domain>[.<key>]                    every write of the key is kept
#   <domain>[.<key>]  <kind>  <path>    the key is offered, this path is kept
# with kinds and paths as in /usr/share/rpi-preseed/paths, of which a filtered
# copy is a valid list. Absent on an ordinary image, where everything applies.
# Under /usr so that it is replaced with the slot it describes, and cannot be
# edited or outlive it as a copy in /etc could.
: "${RPI_PRESEED_DOMAINS:=/usr/lib/rpi-preseed/domains}"

# has_available — does this image say what it can keep?
has_available() {
    [ -f "$(target_path "$RPI_PRESEED_DOMAINS")" ]
}

# awk: load(FILE) reads the list; offered(KEY) and kept(KEY, PATH) query it.
# A [[users]] key drops its index, and a password_encrypted flag goes with
# its password: on its own the hash would be taken for a password.
# shellcheck disable=SC2016  # awk source
AVAILABLE_AWK='
    function norm(k) {
        sub(/^users\.[0-9]+\./, "users.", k); sub(/\.password_encrypted$/, ".password", k)
        return k
    }
    function dom(k) { sub(/\..*/, "", k); return k }
    function under(p, e) { return p == e || index(p, e "/") == 1 }
    function load(file,    line, f, n) {
        while ((getline line < file) > 0) {
            sub(/[[:space:]]*#.*/, "", line)
            n = split(line, f, " ")
            if (n != 1 && n != 3) continue
            ent[++ents] = norm(f[1]); kind[ents] = (n == 3 ? f[2] : ""); path[ents] = f[3]
        }
    }
    function offered(k,    i, whole) {
        k = norm(k); whole = 0
        for (i = 1; i <= ents; i++) {
            if (ent[i] != k && ent[i] != dom(k) && !(k !~ /\./ && dom(ent[i]) == k)) continue
            if (kind[i] == "") whole = 1
            if (!whole) whole = -1
        }
        return whole
    }
    function kept(k, p,    i, o, rel) {
        o = offered(k)
        if (o >= 0) return o
        for (i = 1; i <= ents; i++) {
            if (kind[i] == "file" && p == path[i]) return 1
            if (kind[i] == "dir" && under(p, path[i])) return 1
            if (kind[i] == "boot") {
                rel = p
                if (sub(/^\/boot\/(firmware\/)?/, "", rel) && under(rel, path[i])) return 1
            }
            if (kind[i] == "home" && (rel = index(p, "/" path[i])) &&
                substr(p, rel + length(path[i]) + 1) ~ /^(\/|$)/) return 1
        }
        return 0
    }'

# available KEY — does this image offer KEY? Every key, where it has no list.
available() {
    has_available || return 0
    awk -v k="$1" "$AVAILABLE_AWK"'
        BEGIN { load(ARGV[1]); exit !offered(k) }' "$(target_path "$RPI_PRESEED_DOMAINS")"
}

# persists KEY PATH — would KEY's write to target path PATH survive a reboot?
# An rpi-image-gen A/B image's /etc is writable but on tmpfs, and keeps only
# what its build arranged.
persists() {
    has_available || return 0
    awk -v k="$1" -v p="${2#"$RPI_PRESEED_ROOT"}" "$AVAILABLE_AWK"'
        BEGIN { load(ARGV[1]); exit !kept(k, p) }' "$(target_path "$RPI_PRESEED_DOMAINS")"
}

# drop_unavailable [quiet] — forget every parsed key this image does not
# offer, reporting each skipped unless quiet. Top-level keys are not settings.
drop_unavailable() {
    has_available || return 0
    _du_tmp=$(mktemp) || return 1
    awk -F"$US" -v list="$(target_path "$RPI_PRESEED_DOMAINS")" -v out="$_du_tmp" "$AVAILABLE_AWK"'
        BEGIN { load(list) }
        $2 !~ /\./ || offered($2) { print > out; next }
        !($2 in seen) { seen[$2] = 1; print $2 }' "$TOML_STORE" >"$_du_tmp.skipped"
    cat "$_du_tmp" >"$TOML_STORE"
    if [ -s "$_du_tmp.skipped" ] && [ "${1:-}" != quiet ]; then
        while IFS= read -r _du_k; do
            report_key "$_du_k" skipped "not available on this image"
        done <"$_du_tmp.skipped"
        log_warn "not applied, as $RPI_PRESEED_DOMAINS does not list them: $(tr '\n' ' ' <"$_du_tmp.skipped")"
    fi
    rm -f "$_du_tmp" "$_du_tmp.skipped"
}

# Saves an rpi-image-gen A/B image's /etc to its persistent partition.
: "${SLOT_STATE_SAVE:=/usr/libexec/rpi-persist-files}"

# has_slot_state — is this an rpi-image-gen A/B image?
has_slot_state() {
    [ -x "$SLOT_STATE_SAVE" ]
}

# Applies of one config before its failed settings are given up on.
: "${RPI_PRESEED_BASE_ATTEMPTS:=3}"

# save_persisted — save /etc now. The image does so itself, but only some
# time after a file changes.
save_persisted() {
    has_slot_state || return 0
    # Without the overlay /etc holds the image's defaults, not to be saved.
    [ -n "$RPI_PRESEED_ROOT" ] || mountpoint -q /etc || return 0
    "$SLOT_STATE_SAVE"
}

# writable_or_skip KEY PATH — succeed if PATH can be written and will persist;
# otherwise report KEY skipped. An immutable image mounts /boot/firmware
# read-only.
writable_or_skip() {
    _wos_d=$(dirname "$2")
    while [ ! -d "$_wos_d" ]; do _wos_d=$(dirname "$_wos_d"); done
    if ! writable_dir "$_wos_d"; then
        log_warn "$1: $_wos_d is read-only; not applied"
        report_key "$1" skipped "read-only filesystem"
        return 1
    fi
    persists "$1" "$2" && return 0
    log_warn "$1: ${2#"$RPI_PRESEED_ROOT"} would be lost at reboot; this image does not keep it"
    report_key "$1" skipped "not persisted"
    return 1
}

# keyfile_escape VALUE — VALUE as a GLib key-file string. NetworkManager
# unescapes on load, so a raw "\s" becomes a space, "\d" voids the key and a
# leading space is dropped.
keyfile_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/	/\\t/g' -e 's/^ /\\s/'
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
