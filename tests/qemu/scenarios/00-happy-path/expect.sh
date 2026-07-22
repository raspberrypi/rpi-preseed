# shellcheck shell=dash
# Expectations for 00-happy-path.

qemu_assert_stamp applied "$QEMU_RESULTS_DIR" present
qemu_assert_stamp early-runcmd-done "$QEMU_RESULTS_DIR" present
qemu_assert_stamp runcmd-done "$QEMU_RESULTS_DIR" present
qemu_assert_stamp apply-failed "$QEMU_RESULTS_DIR" absent

qemu_assert_file "report.json captured" "$QEMU_RESULTS_DIR/report.json"
qemu_assert_eq "hostname applied" "$(cat "$QEMU_RESULTS_DIR/hostname" 2>/dev/null)" "qemutest"
qemu_assert_contains "alice in passwd" "$QEMU_RESULTS_DIR/passwd" "alice:x:1000"
