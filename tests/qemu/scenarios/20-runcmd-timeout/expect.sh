# shellcheck shell=dash

qemu_assert_stamp applied "$QEMU_RESULTS_DIR" present
qemu_assert_stamp early-runcmd-done "$QEMU_RESULTS_DIR" present
qemu_assert_contains "early timeout logged" "$QEMU_RESULTS_DIR/journal.txt" "early runcmd[0] failed"
