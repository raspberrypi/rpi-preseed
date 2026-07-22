# shellcheck shell=dash
# shellcheck disable=SC2034  # consumed by tests/qemu/run.sh after sourcing

# Drop the NIC entirely (late phase must not block probe / logins).
QEMU_NO_NETWORK=1
