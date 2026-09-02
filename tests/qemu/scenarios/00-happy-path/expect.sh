# shellcheck shell=dash
# Expectations for 00-happy-path.

qemu_assert_stamp applied "$QEMU_RESULTS_DIR" present
qemu_assert_stamp early-runcmd-done "$QEMU_RESULTS_DIR" present
qemu_assert_stamp runcmd-done "$QEMU_RESULTS_DIR" present
qemu_assert_stamp apply-failed "$QEMU_RESULTS_DIR" absent

qemu_assert_file "report.json captured" "$QEMU_RESULTS_DIR/report.json"
qemu_assert_eq "hostname applied" "$(cat "$QEMU_RESULTS_DIR/hostname" 2>/dev/null)" "qemutest"
qemu_assert_contains "alice in passwd" "$QEMU_RESULTS_DIR/passwd" "alice:x:1000"

# Files written into a home have to belong to the account that reads them: a
# root-owned auth.key at mode 600 is invisible to the systemd *user* unit that
# needs it, and no assertion about the file's contents can tell the difference.
# This image is Pi OS Lite, which does not ship rpi-connect, so the units cannot
# be linked -- the token still has to land, owned, for whenever it is installed.
qemu_assert_file "home artefact manifest captured" "$QEMU_RESULTS_DIR/home-artefacts.txt"
qemu_assert_contains "authorized_keys belongs to the account" \
    "$QEMU_RESULTS_DIR/home-artefacts.txt" ".ssh/authorized_keys alice:alice 600"
qemu_assert_contains "Connect token belongs to the account" \
    "$QEMU_RESULTS_DIR/home-artefacts.txt" ".config/com.raspberrypi.connect/auth.key alice:alice 600"
qemu_assert_contains "Connect directory belongs to the account" \
    "$QEMU_RESULTS_DIR/home-artefacts.txt" ".config/com.raspberrypi.connect alice:alice 700"
qemu_assert_contains "token recorded as applied" "$QEMU_RESULTS_DIR/report.json" "connect.token"
qemu_assert_ncontains "token value stays out of the report" \
    "$QEMU_RESULTS_DIR/report.json" "qemu-not-a-real-token"
qemu_assert_contains "units skipped on an image without rpi-connect" \
    "$QEMU_RESULTS_DIR/report.json" "rpi-connect units not present"
