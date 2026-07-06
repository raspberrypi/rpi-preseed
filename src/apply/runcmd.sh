# shellcheck shell=dash
# rpi-preseed applier — [runcmd]: early (pre-network) and late (post-network).
#
# continue-and-log throughout. Early is held to a tight budget with per-command
# timeouts because user sessions wait on it. Late runs behind a readiness gate
# (clock sync + apt lock) and retries each failed command with capped backoff.

# _run_one CMD TIMEOUT — run CMD via sh -c under an optional timeout; return exit.
# Command stdout/stderr go to the phase .out file (kept separate from our own
# structured .log so diagnostics bundles can exclude arbitrary command output).
_run_one() {
    _ro_cmd="$1"; _ro_to="$2"
    _ro_out=${RUNCMD_OUT:-${LOG_FILE:-/dev/null}}
    if [ -n "$_ro_to" ] && [ "$_ro_to" -gt 0 ] && have timeout; then
        timeout "$_ro_to" sh -c "$_ro_cmd" >>"$_ro_out" 2>&1
    else
        sh -c "$_ro_cmd" >>"$_ro_out" 2>&1
    fi
}

# run_early — execute [runcmd].early with a tight budget.
run_early() {
    _re_tmp=$(mktemp); toml_array runcmd.early >"$_re_tmp"
    if [ ! -s "$_re_tmp" ]; then rm -f "$_re_tmp"; return 0; fi
    _re_to=$(toml_get_default runcmd.early_cmd_timeout 5)
    _re_start=$(date +%s 2>/dev/null || echo 0)
    _re_idx=0
    while IFS= read -r _re_cmd; do
        [ -n "$_re_cmd" ] || continue
        log_info "early runcmd[$_re_idx]: $_re_cmd"
        if _run_one "$_re_cmd" "$_re_to"; then
            report_runcmd early "$_re_idx" "$_re_cmd" 0 1
        else
            _re_rc=$?
            log_warn "early runcmd[$_re_idx] failed (exit $_re_rc); continuing"
            report_runcmd early "$_re_idx" "$_re_cmd" "$_re_rc" 1
        fi
        _re_idx=$((_re_idx + 1))
    done <"$_re_tmp"
    rm -f "$_re_tmp"
    _re_end=$(date +%s 2>/dev/null || echo 0)
    if [ "$((_re_end - _re_start))" -gt 5 ]; then
        log_warn "early runcmd phase exceeded 5s soft budget ($((_re_end - _re_start))s) — early is for fast local ops only"
    fi
    return 0
}

# --- Late-phase readiness gate -------------------------------------------------

_clock_synced() {
    [ -z "$RPI_PRESEED_ROOT" ] || return 0
    [ -e /run/systemd/timesync/synchronized ] && return 0
    if have timedatectl; then
        [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && return 0
    fi
    return 1
}

_apt_locked() {
    [ -z "$RPI_PRESEED_ROOT" ] || return 1
    if have fuser; then
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && return 0
    fi
    return 1
}

_gate_expired() {  # START TIMEOUT
    _ge_now=$(date +%s 2>/dev/null || echo 0)
    [ "$((_ge_now - $1))" -ge "$2" ]
}

_late_gate() {
    _lg_to=$(toml_get_default runcmd.late_gate_timeout 300)
    _lg_start=$(date +%s 2>/dev/null || echo 0)
    if toml_bool runcmd.late_require_time_sync true; then
        while ! _clock_synced; do
            if _gate_expired "$_lg_start" "$_lg_to"; then
                log_warn "late gate: proceeding without time sync (timeout)"; break
            fi
            sleep 2
        done
    fi
    if toml_bool runcmd.late_wait_for_apt_lock true; then
        while _apt_locked; do
            if _gate_expired "$_lg_start" "$_lg_to"; then
                log_warn "late gate: proceeding despite held apt lock (timeout)"; break
            fi
            sleep 2
        done
    fi
}

# _backoff ATTEMPT BASE MAX — print the delay (exponential + jitter, capped).
_backoff() {
    _bo_n="$1"; _bo_base="$2"; _bo_max="$3"
    _bo_d=$_bo_base
    _bo_i=1
    while [ "$_bo_i" -lt "$_bo_n" ]; do _bo_d=$((_bo_d * 2)); _bo_i=$((_bo_i + 1)); done
    [ "$_bo_d" -gt "$_bo_max" ] && _bo_d=$_bo_max
    _bo_j=$(awk 'BEGIN{srand(); print int(rand()*3)}')
    echo $((_bo_d + _bo_j))
}

# run_late — execute [runcmd].late behind the gate with retry/backoff.
run_late() {
    _rl_tmp=$(mktemp); toml_array runcmd.late >"$_rl_tmp"
    if [ ! -s "$_rl_tmp" ]; then rm -f "$_rl_tmp"; return 0; fi

    _late_gate

    _rl_retries=$(toml_get_default runcmd.late_retries 3)
    _rl_delay=$(toml_get_default runcmd.late_retry_delay 5)
    _rl_max=$(toml_get_default runcmd.late_retry_max_delay 300)

    # Politely wait for dpkg locks rather than failing (also honoured by apt).
    export DEBIAN_FRONTEND=noninteractive
    _rl_apt_opt="-o DPkg::Lock::Timeout=300"
    export APT_LOCK_TIMEOUT_OPT="$_rl_apt_opt"

    _rl_idx=0
    while IFS= read -r _rl_cmd; do
        [ -n "$_rl_cmd" ] || continue
        _rl_attempt=1
        _rl_max_attempts=$((_rl_retries + 1))
        while :; do
            log_info "late runcmd[$_rl_idx] attempt $_rl_attempt/$_rl_max_attempts: $_rl_cmd"
            if _run_one "$_rl_cmd" 0; then
                report_runcmd late "$_rl_idx" "$_rl_cmd" 0 "$_rl_attempt"
                break
            fi
            _rl_rc=$?
            if [ "$_rl_attempt" -ge "$_rl_max_attempts" ]; then
                log_warn "late runcmd[$_rl_idx] failed after $_rl_attempt attempts (exit $_rl_rc); continuing"
                report_runcmd late "$_rl_idx" "$_rl_cmd" "$_rl_rc" "$_rl_attempt"
                break
            fi
            _rl_sleep=$(_backoff "$_rl_attempt" "$_rl_delay" "$_rl_max")
            log_warn "late runcmd[$_rl_idx] failed (exit $_rl_rc); retrying in ${_rl_sleep}s"
            sleep "$_rl_sleep"
            _rl_attempt=$((_rl_attempt + 1))
        done
        _rl_idx=$((_rl_idx + 1))
    done <"$_rl_tmp"
    rm -f "$_rl_tmp"
    return 0
}
