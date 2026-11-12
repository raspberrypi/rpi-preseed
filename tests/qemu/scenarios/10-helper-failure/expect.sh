# shellcheck shell=dash

# A setting whose helper fails makes the apply fail: the config keeps its
# secrets and the next boot tries again.
qemu_assert_stamp applied "$QEMU_RESULTS_DIR" absent
qemu_assert_stamp apply-failed "$QEMU_RESULTS_DIR" present
qemu_assert_file "report.json captured" "$QEMU_RESULTS_DIR/report.json"
qemu_assert_contains "hostname key in report" "$QEMU_RESULTS_DIR/report.json" "system.hostname"
