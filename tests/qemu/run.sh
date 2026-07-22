#!/bin/sh
# shellcheck shell=dash
# Rootless qemu-system integration harness for rpi-preseed (-M virt + fuse2fs).

set -eu

QEMU_TESTS=$(cd -- "$(dirname -- "$0")" && pwd)
QEMU_REPO=$(cd -- "$QEMU_TESTS/../.." && pwd)
export QEMU_TESTS QEMU_REPO

# shellcheck source=tests/qemu/lib/common.sh
. "$QEMU_TESTS/lib/common.sh"
# shellcheck source=tests/qemu/lib/download.sh
. "$QEMU_TESTS/lib/download.sh"
# shellcheck source=tests/qemu/lib/mount.sh
. "$QEMU_TESTS/lib/mount.sh"
# shellcheck source=tests/qemu/lib/preflight.sh
. "$QEMU_TESTS/lib/preflight.sh"
# shellcheck source=tests/qemu/lib/debkernel.sh
. "$QEMU_TESTS/lib/debkernel.sh"
# shellcheck source=tests/qemu/lib/image.sh
. "$QEMU_TESTS/lib/image.sh"
# shellcheck source=tests/qemu/lib/provision.sh
. "$QEMU_TESTS/lib/provision.sh"
# shellcheck source=tests/qemu/lib/qemu.sh
. "$QEMU_TESTS/lib/qemu.sh"
# shellcheck source=tests/qemu/lib/faults.sh
. "$QEMU_TESTS/lib/faults.sh"
# shellcheck source=tests/qemu/lib/assert.sh
. "$QEMU_TESTS/lib/assert.sh"

: "${RPI_PRESEED_QEMU_TIMEOUT:=600}"
: "${SCENARIO:=*}"

TESTS=0
FAILS=0
SKIPS=0

ok()  { TESTS=$((TESTS + 1)); printf 'ok   - %s\n' "$1"; }
no()  { TESTS=$((TESTS + 1)); FAILS=$((FAILS + 1)); printf 'FAIL - %s\n' "$1"; }
skip(){ SKIPS=$((SKIPS + 1)); printf 'skip - %s\n' "$1"; }

_qemu_list_scenarios() {
    for _ql in "$QEMU_TESTS/scenarios"/*/; do
        [ -d "$_ql" ] || continue
        _ql_name=$(basename -- "$_ql")
        if [ "$SCENARIO" = "*" ] || [ "$SCENARIO" = "$_ql_name" ]; then
            printf '%s\n' "$_ql_name"
        fi
    done | sort
}

_qemu_run_scenario() {
    _qs_name="$1"
    _qs_dir="$QEMU_TESTS/scenarios/$_qs_name"
    _qs_cfg="$_qs_dir/config.toml"
    _qs_work="$RPI_PRESEED_QEMU_WORK/run/$_qs_name"
    _qs_img="$_qs_work/scenario.qcow2"
    _qs_serial="$_qs_work/serial.log"
    _qs_results="$_qs_work/results"

    printf '== scenario %s ==\n' "$_qs_name"

    QEMU_RUNTIME=none
    QEMU_NO_NETWORK=0
    QEMU_NET_RESTRICT=0
    QEMU_ALLOW_FAIL=0

    if [ -f "$_qs_dir/fault.sh" ]; then
        # shellcheck disable=SC1091
        . "$_qs_dir/fault.sh"
    fi

    ensure_dir "$_qs_work"
    rm -f "$_qs_img"

    qemu_info "cloning base image for $_qs_name..."
    qemu_clone_scenario "$QEMU_PROVISIONED_IMAGE" "$_qs_img"

    qemu_info "planting config on boot partition..."
    qemu_plant_config "$_qs_img" "$_qs_cfg"

    if type scenario_fault_pre >/dev/null 2>&1; then
        qemu_info "applying file-level faults..."
        scenario_fault_pre "$_qs_img"
    fi

    _qs_boot_once() {
        _qs_accel=$(qemu_accel_args)
        qemu_info "booting -M virt ($_qs_accel; serial: $_qs_serial)..."
        qemu_boot "$_qs_img" "$QEMU_KERNEL" "$QEMU_INITRD" "$_qs_serial"
        _qb_pid=$QEMU_PID
        qemu_wait "$_qb_pid" "$RPI_PRESEED_QEMU_TIMEOUT"
        return $?
    }

    if [ "$QEMU_RUNTIME" = power-cut ]; then
        # First boot: in-guest powercut wrapper kills apply mid-run then poweroffs.
        # Second boot: clears the wrapper so real apply-base can recover.
        _qs_boot_once || true
        qemu_info "clearing power-cut wrapper for recovery boot..."
        qemu_rootfs_mount "$_qs_img"
        rm -f "$QEMU_ROOTFS_MNT/etc/systemd/system/rpi-preseed.service.d/powercut.conf"
        rm -rf "$QEMU_ROOTFS_MNT/var/lib/rpi-preseed/qemu-results"
        # Leave any partial applied stamp so ConditionPathExists=!applied may skip —
        # clear apply stamps so recovery re-runs base (idempotent).
        rm -f "$QEMU_ROOTFS_MNT/var/lib/rpi-preseed/applied" \
              "$QEMU_ROOTFS_MNT/var/lib/rpi-preseed/apply-failed" \
              "$QEMU_ROOTFS_MNT/var/lib/rpi-preseed/early-runcmd-done" \
              "$QEMU_ROOTFS_MNT/var/lib/rpi-preseed/runcmd-done"
        qemu_rootfs_umount
        qemu_info "recovery boot after power-cut..."
        _qs_boot_once || true
    else
        if ! _qs_boot_once; then
            if [ "$QEMU_ALLOW_FAIL" = 1 ]; then
                skip "$_qs_name: qemu exited non-zero (allowed)"
            else
                no "$_qs_name: qemu did not shut down cleanly"
                return 1
            fi
        fi
    fi

    qemu_info "collecting probe results..."
    # Journal recovery after abrupt guest stops / unrepaired dirty rootfs.
    qemu_fsck_rootfs "$_qs_img" || true
    if ! qemu_fetch_results "$_qs_img" "$_qs_results"; then
        if [ "$QEMU_ALLOW_FAIL" = 1 ]; then
            skip "$_qs_name: no probe results (allowed)"
            return 0
        fi
        no "$_qs_name: probe did not write results"
        return 1
    fi

    QEMU_RESULTS_DIR="$_qs_results"
    export QEMU_RESULTS_DIR
    # shellcheck disable=SC1091
    . "$_qs_dir/expect.sh"
    return 0
}

main() {
    if [ "${1:-}" = --download-only ]; then
        qemu_download_pios_image_cli
        return 0
    fi

    # Global safety net: reclaim mounts/daemons/guest/staging on any exit,
    # including set -e failures and Ctrl-C, not just the clean path.
    trap 'qemu_teardown' EXIT INT TERM

    qemu_cleanup_stale_mounts

    if ! qemu_preflight; then
        qemu_die "preflight failed — install qemu-system-arm, fuse2fs, mtools, qemu-utils"
    fi

    qemu_prepare_image
    _qpi_cache_dir=$(dirname -- "$QEMU_PREPARED_IMAGE")
    qemu_prepare_provisioned_image "$QEMU_PREPARED_IMAGE" "$_qpi_cache_dir"

    _qm_scenarios=$(_qemu_list_scenarios)
    if [ -z "$_qm_scenarios" ]; then
        qemu_die "no scenarios match SCENARIO=$SCENARIO"
    fi

    _qm_failed=0
    for _qm_s in $_qm_scenarios; do
        if ! _qemu_run_scenario "$_qm_s"; then
            _qm_failed=1
        fi
    done

    echo "-------------------------------------"
    printf '%d checks, %d failures, %d skipped scenarios\n' "$TESTS" "$FAILS" "$SKIPS"
    [ "$FAILS" -eq 0 ] && [ "$_qm_failed" -eq 0 ]
}

main "$@"
