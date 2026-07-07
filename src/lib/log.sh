# shellcheck shell=dash
# rpi-preseed — logging, structured report, and boot-partition breadcrumb.
#
# All sinks pass through the redactor. Per-phase logs are appended and synced so a
# power-cut mid-apply still leaves a record. A machine-readable report.json plus a
# redacted FAT-partition breadcrumb are written at the end of a run.

LOG_IDENT="rpi-preseed"
LOG_PHASE="main"

# log_init PHASE — start logging for a phase.
#
# The report scratch (REPORT_KEYS/REPORT_CMDS) is CUMULATIVE across the phases
# of one apply run (base -> runcmd-early -> runcmd-late), which run as separate
# processes on boot. Keeping it in STATE_DIR and appending means the final
# report.json reflects the whole run rather than only the last phase (which was
# previously empty). report_reset() clears it at the start of a fresh base apply.
log_init() {
    LOG_PHASE="$1"
    ensure_dir "$LOG_DIR" 755 2>/dev/null || true
    LOG_FILE="$LOG_DIR/$LOG_PHASE.log"
    ensure_dir "$STATE_DIR" 755 2>/dev/null || true
    REPORT_KEYS="$STATE_DIR/report.keys.tab"
    REPORT_CMDS="$STATE_DIR/report.cmds.tab"
    [ -f "$REPORT_KEYS" ] || : >"$REPORT_KEYS" 2>/dev/null || true
    [ -f "$REPORT_CMDS" ] || : >"$REPORT_CMDS" 2>/dev/null || true
}

# report_reset — begin a fresh cumulative report. Called at the start of a base
# apply so a re-apply (or a new config) does not accrete stale key results.
report_reset() {
    REPORT_KEYS="${REPORT_KEYS:-$STATE_DIR/report.keys.tab}"
    REPORT_CMDS="${REPORT_CMDS:-$STATE_DIR/report.cmds.tab}"
    : >"$REPORT_KEYS" 2>/dev/null || true
    : >"$REPORT_CMDS" 2>/dev/null || true
}

# _log LEVEL MSG — timestamp + redact + fan out to file, journal and stderr.
_log() {
    _lg_level="$1"; shift
    _lg_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo -)
    _lg_msg=$(redact_line "$*")
    _lg_out="$_lg_ts $_lg_level [$LOG_PHASE] $_lg_msg"
    if [ -n "${LOG_FILE:-}" ]; then
        printf '%s\n' "$_lg_out" >>"$LOG_FILE" 2>/dev/null || true
        sync "$LOG_FILE" 2>/dev/null || true
    fi
    if have systemd-cat; then
        printf '%s\n' "$_lg_msg" | systemd-cat -t "$LOG_IDENT" -p "$_lg_level" 2>/dev/null || true
    elif have logger; then
        logger -t "$LOG_IDENT" -p "user.$_lg_level" -- "$_lg_msg" 2>/dev/null || true
    fi
    printf '%s\n' "$_lg_out" >&2
}

log_info()  { _log info "$@"; }
log_warn()  { _log warning "$@"; }
log_error() { _log err "$@"; }

# report_key KEY STATUS [DETAIL] — record a per-key outcome.
report_key() {
    [ -n "${REPORT_KEYS:-}" ] || return 0
    printf '%s%s%s%s%s\n' "$1" "$US" "$2" "$US" "${3:-}" >>"$REPORT_KEYS" 2>/dev/null || true
}

# report_runcmd PHASE INDEX COMMAND EXIT ATTEMPTS — record a runcmd outcome.
report_runcmd() {
    [ -n "${REPORT_CMDS:-}" ] || return 0
    printf '%s%s%s%s%s%s%s%s%s\n' \
        "$1" "$US" "$2" "$US" "$3" "$US" "$4" "$US" "$5" >>"$REPORT_CMDS" 2>/dev/null || true
}

# _json_str STRING — emit a redacted, JSON-escaped quoted string.
_json_str() {
    _js=$(redact_line "$1")
    _js=$(printf '%s' "$_js" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g')
    printf '"%s"' "$_js"
}

# report_write STATUS — assemble report.json and the breadcrumb.
report_write() {
    _rw_status="$1"
    ensure_dir "$STATE_DIR" 755 2>/dev/null || true
    {
        printf '{\n'
        printf '  "version": %s,\n' "$(_json_str "${RPI_PRESEED_VERSION:-0}")"
        printf '  "config_fingerprint": %s,\n' "$(_json_str "${CONFIG_FINGERPRINT:-none}")"
        printf '  "timestamp": %s,\n' "$(_json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo -)")"
        printf '  "phase": %s,\n' "$(_json_str "$LOG_PHASE")"
        printf '  "status": %s,\n' "$(_json_str "$_rw_status")"
        printf '  "keys": [\n'
        _rw_first=1
        if [ -f "${REPORT_KEYS:-/nonexistent}" ]; then
            while IFS="$US" read -r _rw_k _rw_s _rw_d; do
                [ -n "$_rw_k" ] || continue
                [ "$_rw_first" -eq 1 ] || printf ',\n'
                _rw_first=0
                printf '    {"key": %s, "status": %s, "detail": %s}' \
                    "$(_json_str "$_rw_k")" "$(_json_str "$_rw_s")" "$(_json_str "$_rw_d")"
            done <"$REPORT_KEYS"
        fi
        printf '\n  ],\n'
        printf '  "runcmd": [\n'
        _rw_first=1
        if [ -f "${REPORT_CMDS:-/nonexistent}" ]; then
            while IFS="$US" read -r _rw_p _rw_i _rw_c _rw_e _rw_a; do
                [ -n "$_rw_p" ] || continue
                [ "$_rw_first" -eq 1 ] || printf ',\n'
                _rw_first=0
                printf '    {"phase": %s, "index": %s, "command": %s, "exit": %s, "attempts": %s}' \
                    "$(_json_str "$_rw_p")" "${_rw_i:-0}" "$(_json_str "$_rw_c")" "${_rw_e:-0}" "${_rw_a:-1}"
            done <"$REPORT_CMDS"
        fi
        printf '\n  ]\n'
        printf '}\n'
    } | atomic_write "$STATE_DIR/report.json"

    breadcrumb_write "$_rw_status"
}

# breadcrumb_write STATUS — mirror a redacted summary to the FAT boot partition.
breadcrumb_write() {
    # Skip if the boot dir is not present or not writable (e.g. RO secure-boot).
    [ -d "$RPI_PRESEED_BOOT_DIR" ] || return 0
    ensure_dir "$BREADCRUMB_DIR" 755 2>/dev/null || return 0
    {
        printf 'rpi-preseed status\n'
        printf 'phase:       %s\n' "$LOG_PHASE"
        printf 'status:      %s\n' "$1"
        printf 'version:     %s\n' "${RPI_PRESEED_VERSION:-0}"
        printf 'fingerprint: %s\n' "${CONFIG_FINGERPRINT:-none}"
        printf 'timestamp:   %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo -)"
    } | atomic_write "$BREADCRUMB_DIR/status.txt" 2>/dev/null || true
    if [ -f "$STATE_DIR/report.json" ]; then
        cp -f "$STATE_DIR/report.json" "$BREADCRUMB_DIR/report.json" 2>/dev/null || true
    fi
}

# log_cleanup — end-of-phase cleanup.
#
# The report scratch is intentionally NOT removed here: it is cumulative across
# phases and is reset by report_reset() at the next base apply. Removing it
# would drop base-phase results before the runcmd phases re-render report.json.
log_cleanup() {
    :
}
