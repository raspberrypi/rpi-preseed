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
