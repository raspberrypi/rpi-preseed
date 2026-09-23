#!/bin/sh
# Secret redaction against a real FAT boot partition, read back from the raw
# image. Opt-in (not part of `make test`): needs sudo for the loop mount, and
# mkfs.vfat.
#
#   sh tests/redact_fat.sh

# check() evals its test, so expansions in single quotes are deliberate.
# shellcheck disable=SC2016

set -eu

REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
SECRET="Burn-This-Passphrase-9e1d"
MKFS=$(command -v mkfs.vfat || echo /usr/sbin/mkfs.vfat)

work=$(mktemp -d)
img="$work/fat.img"
mnt="$work/mnt"
root="$work/root"
mkdir "$mnt"

cleanup() {
    mountpoint -q "$mnt" && sudo umount "$mnt"
    rm -rf "$work"
}
trap cleanup EXIT

fails=0
check() {
    if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi
}

mount_fat() { sudo mount -o "loop,uid=$(id -u),gid=$(id -g)" "$img" "$mnt"; }

# fresh_fat HOSTNAME — new FAT image and sandbox root, config planted on FAT.
fresh_fat() {
    mountpoint -q "$mnt" && sudo umount "$mnt"
    rm -rf "$img" "$root"
    truncate -s 64M "$img"
    "$MKFS" -F 32 "$img" >/dev/null
    mount_fat
    mkdir -p "$root/etc" "$root/home/pi"
    echo "pi:x:1000:1000:,,,:/home/pi:/bin/bash" >"$root/etc/passwd"
    cat >"$mnt/rpi-preseed.toml" <<EOF
config_version = "1.0"
[system]
hostname = "$1"
[wlan]
ssid = "HomeNet"
password = "$SECRET"
EOF
    sync
}

raw_has_secret() {
    sudo umount "$mnt"
    _rc=0
    grep -qaF "$SECRET" "$img" || _rc=1
    mount_fat
    return "$_rc"
}

rpp() {
    env -u RPI_PRESEED_STATE_DIR RPI_PRESEED_ROOT="$root" RPI_PRESEED_BOOT_DIR="$mnt" \
        RPI_PRESEED_CONFIG="$mnt/rpi-preseed.toml" \
        RPI_PRESEED_SCHEMA="$REPO/schema/rpi-preseed.schema" \
        sh "$REPO/src/rpi-preseed" "$@" >/dev/null 2>&1
}

# --- Control: sed -i, as redaction used to, leaves the secret on disk --------
fresh_fat mypi
check "control: secret is on the raw image" 'raw_has_secret'
sed -i 's/^password = .*/password = "x"/' "$mnt/rpi-preseed.toml"
check "control: after sed -i the secret is still on the raw image" 'raw_has_secret'

# --- A failed apply keeps the secret, so the config can be debugged ----------
fresh_fat "not a valid hostname!"
rpp apply --phase base || true
check "apply failed" '[ -f "$root/var/lib/rpi-preseed/apply-failed" ]'
check "failed apply keeps the secret in the config" 'grep -qF "$SECRET" "$mnt/rpi-preseed.toml"'

# --- A successful apply redacts, and burns the old blocks --------------------
fresh_fat mypi
rpp apply --phase base
check "apply succeeded" '[ -f "$root/var/lib/rpi-preseed/applied" ]'
check "secret consumed into the connection" 'grep -qF "psk=$SECRET" "$root/etc/NetworkManager/system-connections/preconfigured.nmconnection"'
check "secret gone from the config" '! grep -qF "$SECRET" "$mnt/rpi-preseed.toml"'
check "rest of the config kept" 'grep -qF "ssid = \"HomeNet\"" "$mnt/rpi-preseed.toml"'
check "secret gone from the raw image" '! raw_has_secret'

echo "$fails failures"
[ "$fails" -eq 0 ]
