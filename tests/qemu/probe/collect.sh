#!/bin/sh
# shellcheck shell=dash
# Collect rpi-preseed state after first boot, then power off the VM.

set -eu

OUT=/var/lib/rpi-preseed/qemu-results
STAMP_DIR=$OUT/stamps
STATE=/var/lib/rpi-preseed
BOOT=/boot/firmware/rpi-preseed

mkdir -p "$STAMP_DIR"

# Wait for rpi-preseed units to finish (or fail) before collecting.
_wait_preseed() {
    _wp_deadline=$(($(date +%s 2>/dev/null || echo 0) + 360))
    _wp_late_wanted=0
    if [ -f /etc/systemd/system/multi-user.target.wants/rpi-preseed-runcmd-late.service ]; then
        _wp_late_wanted=1
    fi
    while :; do
        [ -f "$STATE/apply-failed" ] && return 0
        if [ "$_wp_late_wanted" -eq 1 ] && [ -f "$STATE/applied" ] && [ ! -f "$STATE/runcmd-done" ]; then
            _wp_now=$(date +%s 2>/dev/null || echo 0)
            [ "$_wp_now" -ge "$_wp_deadline" ] && return 0
            sleep 3
            continue
        fi
        if [ -f "$STATE/runcmd-done" ]; then
            return 0
        fi
        if [ -f "$STATE/applied" ]; then
            _wp_early=0
            if [ -f /etc/systemd/system/multi-user.target.wants/rpi-preseed-runcmd-early.service ]; then
                _wp_early=1
            fi
            if [ "$_wp_late_wanted" -eq 0 ] && [ "$_wp_early" -eq 1 ] && [ -f "$STATE/early-runcmd-done" ]; then
                return 0
            fi
            if [ "$_wp_late_wanted" -eq 0 ] && [ "$_wp_early" -eq 0 ]; then
                return 0
            fi
        fi
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl is-active --quiet rpi-preseed.service 2>/dev/null \
               || systemctl is-active --quiet rpi-preseed-runcmd-early.service 2>/dev/null; then
                :
            elif [ -f "$STATE/applied" ] || [ -f "$STATE/apply-failed" ]; then
                return 0
            fi
        fi
        _wp_now=$(date +%s 2>/dev/null || echo 0)
        [ "$_wp_now" -ge "$_wp_deadline" ] && return 0
        sleep 3
    done
}

_wait_preseed

{
    printf 'date=%s\n' "$(date -u 2>/dev/null || echo unknown)"
    printf 'uname=%s\n' "$(uname -a 2>/dev/null || echo unknown)"
    if command -v rpi-preseed >/dev/null 2>&1; then
        rpi-preseed status 2>&1 || true
    fi
} >"$OUT/status.txt"

for _s in applied early-runcmd-done runcmd-done apply-failed; do
    if [ -f "$STATE/$_s" ]; then
        cp -a "$STATE/$_s" "$STAMP_DIR/$_s"
    fi
done

[ -f "$STATE/report.json" ] && cp -a "$STATE/report.json" "$OUT/report.json"
[ -f "$BOOT/status.txt" ] && cp -a "$BOOT/status.txt" "$OUT/breadcrumb.txt"
[ -f /etc/hostname ] && cp -a /etc/hostname "$OUT/hostname"
[ -f /etc/passwd ] && cp -a /etc/passwd "$OUT/passwd"

# Owner and mode of everything rpi-preseed writes inside a user's home. Recorded
# as text, and by path relative to the home, because the results are fetched off
# the guest -- where the numeric ids mean nothing and the home's name varies with
# the scenario. This is the only layer that can see ownership at all: the
# unprivileged sandbox suite cannot chown, so it asserts modes and leaves the
# owner to this.
_ch_home=$(getent passwd 1000 2>/dev/null | cut -d: -f6)
{
    if [ -n "$_ch_home" ]; then
        for _ch_p in .ssh .ssh/authorized_keys \
                     .config/com.raspberrypi.connect \
                     .config/com.raspberrypi.connect/auth.key \
                     .config/systemd/user \
                     .config/systemd/user/default.target.wants \
                     .config/systemd/user/paths.target.wants; do
            [ -e "$_ch_home/$_ch_p" ] || continue
            printf '%s %s %s\n' "$_ch_p" \
                "$(stat -c '%U:%G' "$_ch_home/$_ch_p" 2>/dev/null)" \
                "$(stat -c '%a' "$_ch_home/$_ch_p" 2>/dev/null)"
        done
    fi
    _ch_user=$(getent passwd 1000 2>/dev/null | cut -d: -f1)
    if [ -n "$_ch_user" ] && [ -e "/var/lib/systemd/linger/$_ch_user" ]; then
        printf 'linger present\n'
    fi
} >"$OUT/home-artefacts.txt"
[ -f /boot/firmware/rpi-preseed.toml ] && cp -a /boot/firmware/rpi-preseed.toml "$OUT/config.toml"

if command -v journalctl >/dev/null 2>&1; then
    journalctl -u 'rpi-preseed*' --no-pager >"$OUT/journal.txt" 2>/dev/null || true
fi

if [ -d "$STATE/log" ]; then
    mkdir -p "$OUT/log"
    cp -a "$STATE/log/." "$OUT/log/" 2>/dev/null || true
fi

: >"$OUT/done"
sync
systemctl poweroff
