# shellcheck shell=dash

qemu_assert_stamp applied "$QEMU_RESULTS_DIR" present
qemu_assert_file "report.json captured" "$QEMU_RESULTS_DIR/report.json"
# Hostname may fall back to file-based path when imager_custom fails; either way
# base apply should complete and record outcomes.
qemu_assert_contains "hostname key in report" "$QEMU_RESULTS_DIR/report.json" "system.hostname"
