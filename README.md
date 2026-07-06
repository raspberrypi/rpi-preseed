# rpi-preseed

A greenfield, cloud-init-free first-boot OS customisation system for Raspberry Pi OS.

`rpi-preseed` reads a single human-friendly **TOML** file and applies it on first
boot, from booted systemd oneshots, reusing the proven Raspberry Pi helper scripts
(`imager_custom`, `userconf`, `raspi-config nonint`) with native POSIX-shell
fallbacks. Arbitrary `runcmd`s run in two further phases (before and after the
network is up).

## Layout

```
src/rpi-preseed          # main orchestrator + CLI (POSIX sh)
src/lib/                 # toml parser, validator, redactor, logging, common helpers
src/apply/               # per-domain appliers
systemd/                 # oneshot units, target, user@ drop-in
schema/rpi-preseed.schema# single source of truth: key -> type + data-class
examples/                # example configuration
doc/                     # man page
debian/                  # Debian packaging
tests/                   # unit tests + shellcheck runner
```

## CLI

```
rpi-preseed apply [--phase all|base|early|late]   # apply now, ignoring stamps
rpi-preseed reset [--phase ...]                    # clear stamps; re-run next boot
rpi-preseed status                                 # show applied state
rpi-preseed collect-logs [--include-runcmd-output] # build a redacted diagnostics bundle
```

## Development

```
make check          # shellcheck + unit tests
make test           # unit tests only
```

The scripts honour these environment overrides so they can run unprivileged in a
test sandbox (no root, no real `/boot`):

- `RPI_PRESEED_ROOT`      target rootfs prefix (default empty = `/`)
- `RPI_PRESEED_STATE_DIR` state/stamp/log dir (default `$ROOT/var/lib/rpi-preseed`)
- `RPI_PRESEED_BOOT_DIR`  boot partition dir (default `$ROOT/boot/firmware`)
- `RPI_PRESEED_CONFIG`    explicit config path (overrides cmdline/default lookup)
- `RPI_PRESEED_SCHEMA`    schema table path
- `RPI_PRESEED_LIBDIR` / `RPI_PRESEED_APPLYDIR`  code locations

## Status

Prototype. Not yet production-hardened.

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE).
