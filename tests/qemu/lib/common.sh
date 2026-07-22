# shellcheck shell=dash
# Shared helpers for the qemu integration harness.
# QEMU_TESTS and QEMU_REPO are set by tests/qemu/run.sh before this file is sourced.

# Work/cache locations (overridable). Default is on-disk user cache, not tmpfs.
if [ -z "${RPI_PRESEED_QEMU_WORK:-}" ]; then
    if [ -n "${XDG_CACHE_HOME:-}" ]; then
        RPI_PRESEED_QEMU_WORK="$XDG_CACHE_HOME/rpi-preseed-qemu"
    elif [ -n "${HOME:-}" ]; then
        RPI_PRESEED_QEMU_WORK="$HOME/.cache/rpi-preseed-qemu"
    else
        RPI_PRESEED_QEMU_WORK="${TMPDIR:-/tmp}/rpi-preseed-qemu"
    fi
fi
: "${RPI_PRESEED_QEMU_CACHE:=$RPI_PRESEED_QEMU_WORK/cache}"
export RPI_PRESEED_QEMU_WORK RPI_PRESEED_QEMU_CACHE

qemu_have() {
    command -v "$1" >/dev/null 2>&1
}

qemu_die() {
    printf 'qemu-harness: %s\n' "$*" >&2
    exit 1
}

qemu_info() {
    printf 'qemu-harness: %s\n' "$*" >&2
}

qemu_warn() {
    printf 'qemu-harness: warning: %s\n' "$*" >&2
}

# sha256_file PATH — stable fingerprint for cache keys.
sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

ensure_dir() {
    [ -d "$1" ] && return 0
    mkdir -p "$1"
}
