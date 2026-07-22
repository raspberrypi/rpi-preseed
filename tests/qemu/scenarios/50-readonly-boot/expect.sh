# shellcheck shell=dash

qemu_assert_stamp applied "$QEMU_RESULTS_DIR" present
qemu_assert_contains "secret still in readonly config" "$QEMU_RESULTS_DIR/config.toml" "SUPERSECRETPSK"
qemu_assert_ncontains "secret not in report" "$QEMU_RESULTS_DIR/report.json" "SUPERSECRETPSK"
qemu_assert_contains "readonly skip logged" "$QEMU_RESULTS_DIR/journal.txt" "skipping secret redaction"
