# shellcheck shell=dash

qemu_assert_stamp applied "$QEMU_RESULTS_DIR" absent
qemu_assert_stamp apply-failed "$QEMU_RESULTS_DIR" present
