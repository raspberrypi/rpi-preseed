# shellcheck shell=dash

qemu_assert_stamp applied "$QEMU_RESULTS_DIR" present
qemu_assert_stamp runcmd-done "$QEMU_RESULTS_DIR" present
qemu_assert_contains "late retry logged" "$QEMU_RESULTS_DIR/journal.txt" "retrying in"
