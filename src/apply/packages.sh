# shellcheck shell=dash
# rpi-preseed applier — [packages]: declarative apt package management.
#
# Runs in the late phase (post-network, behind the readiness gate) because it
# needs the network and the dpkg lock. Each apt step is retried with the same
# capped backoff as runcmd.late. Offline/sandbox runs (no root or no apt-get)
# report the request as skipped rather than pretending to install.

# apply_packages — apply [packages] via apt-get. Assumes the late gate has run and
# DEBIAN_FRONTEND / APT_LOCK_TIMEOUT_OPT are already exported by run_late().
apply_packages() {
    _ap_install=$(_pkg_join packages.install)
    _ap_remove=$(_pkg_join packages.remove)
    _ap_update=0; toml_bool packages.update false && _ap_update=1
    _ap_upgrade=0; toml_bool packages.upgrade false && _ap_upgrade=1

    if ! helpers_live || ! have apt-get; then
        log_warn "packages: apt-get unavailable (offline or unprivileged); skipping"
        report_key packages skipped "apt-get unavailable"
        return 0
    fi

    _ap_retries=$(toml_get_default runcmd.late_retries 3)
    _ap_delay=$(toml_get_default runcmd.late_retry_delay 5)
    _ap_max=$(toml_get_default runcmd.late_retry_max_delay 300)

    # apt refreshes the index for update, install and upgrade; do it once up front.
    if [ "$_ap_update" -eq 1 ] || [ -n "$_ap_install" ] || [ "$_ap_upgrade" -eq 1 ]; then
        _pkg_run packages.update "apt-get $APT_LOCK_TIMEOUT_OPT -y update"
    fi
    if [ "$_ap_upgrade" -eq 1 ]; then
        _pkg_run packages.upgrade "apt-get $APT_LOCK_TIMEOUT_OPT -y dist-upgrade"
    fi
    if [ -n "$_ap_install" ]; then
        _pkg_run packages.install "apt-get $APT_LOCK_TIMEOUT_OPT -y install $_ap_install"
    fi
    if [ -n "$_ap_remove" ]; then
        _pkg_run packages.remove "apt-get $APT_LOCK_TIMEOUT_OPT -y remove $_ap_remove"
    fi
    return 0
}

# _pkg_join KEY — join a TOML string array into a single space-separated line.
_pkg_join() {
    toml_array "$1" | while IFS= read -r _pj_e; do
        [ -n "$_pj_e" ] || continue
        printf '%s ' "$_pj_e"
    done
}

# _pkg_run KEY CMD — run an apt step with retry/backoff; record the outcome.
_pkg_run() {
    _pr_key="$1"; _pr_cmd="$2"
    _pr_retries=${_ap_retries:-3}
    _pr_attempt=1
    _pr_max_attempts=$((_pr_retries + 1))
    while :; do
        log_info "packages: $_pr_key attempt $_pr_attempt/$_pr_max_attempts: $_pr_cmd"
        if _run_one "$_pr_cmd" 0; then
            report_key "$_pr_key" applied "apt-get"
            return 0
        fi
        _pr_rc=$?
        if [ "$_pr_attempt" -ge "$_pr_max_attempts" ]; then
            log_warn "packages: $_pr_key failed after $_pr_attempt attempts (exit $_pr_rc); continuing"
            report_key "$_pr_key" failed "exit $_pr_rc"
            return 1
        fi
        _pr_sleep=$(_backoff "$_pr_attempt" "${_ap_delay:-5}" "${_ap_max:-300}")
        log_warn "packages: $_pr_key failed (exit $_pr_rc); retrying in ${_pr_sleep}s"
        sleep "$_pr_sleep"
        _pr_attempt=$((_pr_attempt + 1))
    done
}
