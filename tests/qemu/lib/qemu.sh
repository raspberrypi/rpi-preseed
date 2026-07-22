# shellcheck shell=dash
# Launch -M virt under qemu-system-aarch64 (KVM when available, else TCG).

# qemu_accel_args — print -enable-kvm/-cpu (or TCG cpu) for this host.
qemu_accel_args() {
    if [ -c /dev/kvm ] 2>/dev/null && [ "$(uname -m)" = aarch64 ]; then
        printf '%s' "-enable-kvm -cpu host"
        return 0
    fi
    # Cross-arch or no KVM: TCG with a reasonable aarch64 CPU model.
    printf '%s' "-cpu cortex-a72"
}

# qemu_boot IMAGE KERNEL INITRD SERIAL_LOG [QEMU_EXTRA_ARGS...]
# Sets QEMU_PID. Returns when qemu exits (poweroff, fault kill, or watchdog).
qemu_boot() {
    _qb_img="$1"
    _qb_kernel="$2"
    _qb_initrd="$3"
    _qb_serial="$4"
    shift 4

    : >"$_qb_serial"

    _qb_net=""
    if [ "${QEMU_NO_NETWORK:-0}" = 1 ]; then
        _qb_net=""
    elif [ "${QEMU_NET_RESTRICT:-0}" = 1 ]; then
        _qb_net="-netdev user,id=n0,restrict=on -device virtio-net-pci,netdev=n0"
    else
        _qb_net="-netdev user,id=n0 -device virtio-net-pci,netdev=n0"
    fi

    _qb_fmt=raw
    case "$_qb_img" in
        *.qcow2) _qb_fmt=qcow2 ;;
    esac

    _qb_accel=$(qemu_accel_args)
    _qb_mem="${RPI_PRESEED_QEMU_MEM:-2048}"
    _qb_smp="${RPI_PRESEED_QEMU_SMP:-4}"

    # shellcheck disable=SC2086
    qemu-system-aarch64 \
        -M virt \
        -m "$_qb_mem" \
        -smp "$_qb_smp" \
        $_qb_accel \
        -kernel "$_qb_kernel" \
        -initrd "$_qb_initrd" \
        -drive "file=$_qb_img,format=$_qb_fmt,if=none,id=hd0,cache=writeback" \
        -device virtio-blk-pci,drive=hd0 \
        -append "root=/dev/vda2 rootfstype=ext4 rw fsck.repair=yes console=ttyAMA0,115200" \
        $_qb_net \
        -serial "file:$_qb_serial" \
        -display none \
        -monitor none \
        "$@" &

    QEMU_PID=$!
    export QEMU_PID
}

# qemu_wait PID TIMEOUT SECONDS — kill if still running after TIMEOUT.
qemu_wait() {
    _qw_pid="$1"
    _qw_to="$2"
    _qw_start=$(date +%s 2>/dev/null || echo 0)
    while kill -0 "$_qw_pid" 2>/dev/null; do
        _qw_now=$(date +%s 2>/dev/null || echo 0)
        if [ "$((_qw_now - _qw_start))" -ge "$_qw_to" ]; then
            qemu_warn "watchdog: killing qemu pid $_qw_pid after ${_qw_to}s"
            kill -9 "$_qw_pid" 2>/dev/null || true
            wait "$_qw_pid" 2>/dev/null || true
            return 124
        fi
        sleep 2
    done
    wait "$_qw_pid" 2>/dev/null
    return $?
}

# qemu_watch_serial SERIAL_LOG MARKER — background: kill QEMU_PID when MARKER appears.
qemu_watch_serial() {
    _ws_log="$1"
    _ws_marker="$2"
    _ws_pid="$3"
    (
        while kill -0 "$_ws_pid" 2>/dev/null; do
            if [ -f "$_ws_log" ] && grep -qF -- "$_ws_marker" "$_ws_log" 2>/dev/null; then
                # Brief delay so the apply actually starts mutating disk, then
                # abrupt kill (SIGKILL) to simulate power loss.
                sleep 3
                kill -9 "$_ws_pid" 2>/dev/null || true
                break
            fi
            sleep 1
        done
    ) &
    QEMU_WATCH_PID=$!
    export QEMU_WATCH_PID
}

qemu_stop_watch() {
    if [ -n "${QEMU_WATCH_PID:-}" ]; then
        kill "$QEMU_WATCH_PID" 2>/dev/null || true
        wait "$QEMU_WATCH_PID" 2>/dev/null || true
        unset QEMU_WATCH_PID
    fi
}
