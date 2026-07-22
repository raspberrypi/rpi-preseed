# shellcheck shell=dash
# After power-cut + recovery boot, base apply should eventually succeed.

qemu_assert_stamp applied "$QEMU_RESULTS_DIR" present
qemu_assert_eq "hostname recovered" "$(cat "$QEMU_RESULTS_DIR/hostname" 2>/dev/null)" "powercut"
qemu_assert_contains "user renamed after recovery" "$QEMU_RESULTS_DIR/passwd" "cutuser:x:1000"
