# shellcheck shell=dash
# Best-effort: without network, late phase should still finish and not block boot.

qemu_assert_stamp applied "$QEMU_RESULTS_DIR" present
qemu_assert_stamp runcmd-done "$QEMU_RESULTS_DIR" present
qemu_assert_file "probe completed despite no network" "$QEMU_RESULTS_DIR/done"
