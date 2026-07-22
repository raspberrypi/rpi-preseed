# shellcheck shell=dash

qemu_assert_stamp applied "$QEMU_RESULTS_DIR" absent
qemu_assert_stamp apply-failed "$QEMU_RESULTS_DIR" present
# Strict TOML parsers report "failed to parse"; the shell toml helper logs malformed lines.
qemu_assert_contains "parse failure logged" "$QEMU_RESULTS_DIR/journal.txt" "malformed"
