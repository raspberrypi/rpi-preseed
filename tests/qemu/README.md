# qemu-system integration tests for rpi-preseed

Rootless integration tests that boot a **real Raspberry Pi OS Lite arm64** rootfs under
`qemu-system-aarch64 -M virt` (KVM on aarch64 when `/dev/kvm` is available), inject
`rpi-preseed` with **fuse2fs** / **mtools** (no libguestfs appliance), run the real
systemd first-boot units, and verify behaviour via a probe that collects state and
powers off the VM.

These tests are **opt-in** (not part of `make check`).

## Prerequisites

```bash
sudo apt install qemu-system-arm qemu-utils fuse2fs mtools xz-utils util-linux \
  linux-image-arm64 initramfs-tools
```

- **Boot kernel**: Debian `linux-image-arm64` (virtio). Pi `*rpt*` kernels cannot boot `-M virt`.
- **Initrd**: harness builds a cached virtio initrd via `mkinitramfs` (host `MODULES=dep` initrds often lack virtio).
- **No native arm64 kernel (e.g. x86_64 CI)**: when `/boot` has no `linux-image-arm64`, the
  harness auto-fetches a Debian arm64 kernel `.deb` from the Debian mirror and builds a matching
  virtio initrd (with a static arm64 `busybox`) entirely rootless — no `linux-image-arm64` install
  needed on the host. Cached under `~/.cache/rpi-preseed-qemu/cache/debian-kernel/`. Disable with
  `RPI_PRESEED_QEMU_AUTO_DOWNLOAD=0`, or bypass with `RPI_PRESEED_QEMU_KERNEL` / `_INITRD`.
- **Acceleration**: aarch64 + `/dev/kvm` → `-enable-kvm -cpu host`; else TCG.
- **Image edits**: `fuse2fs` (ext4) + `mtools` (FAT); qcow2 via `qemu-storage-daemon` FUSE export.
- **Rootfs grow**: partition grow uses `losetup`+`resize2fs` when available (fuse2fs alone cannot expand).

## Pi OS image

By default the harness **downloads** Raspberry Pi OS Lite (64-bit) (cached under
`~/.cache/rpi-preseed-qemu/`). Pin in [`pios-image.conf`](pios-image.conf).

```bash
make qemu-download
make qemu-check
make qemu-check SCENARIO=00-happy-path
```

| Variable | Purpose |
|----------|---------|
| `RPI_PRESEED_QEMU_IMAGE` | Local `.img` / `.img.xz` |
| `RPI_PRESEED_QEMU_KERNEL` / `_INITRD` | Override Debian boot kernel/initrd |
| `RPI_PRESEED_QEMU_TIMEOUT` | Watchdog seconds (default 600) |
| `RPI_PRESEED_QEMU_MEM` / `_SMP` | Guest RAM MiB / vCPUs (2048 / 4) |
| `RPI_PRESEED_QEMU_DEBIAN_MIRROR` | Debian mirror for auto-fetched kernel (`https://deb.debian.org/debian`) |
| `RPI_PRESEED_QEMU_DEBIAN_SUITE` | Debian suite for auto-fetched kernel (`trixie`) |
| `RPI_PRESEED_QEMU_BUSYBOX` | Static arm64 busybox for the built initrd (else auto-fetched) |

## How it works

1. Cache a prepared Pi OS disk image.
2. One-time: `make install DESTDIR=` and copy into the rootfs via fuse2fs; enable units + probe.
3. Per scenario: qcow2 clone, plant `rpi-preseed.toml` on the FAT boot partition, optional faults.
4. Boot `-M virt` with Debian `vmlinuz`+`initrd`, `root=/dev/vda2`, virtio-net.
5. Probe writes `/var/lib/rpi-preseed/qemu-results/` and powers off; host copies results out via fuse2fs.

## Scenarios

| Scenario | Purpose |
|----------|---------|
| `00-happy-path` | Full base + early + late apply |
| `01-invalid-toml` | Malformed config → `apply-failed` |
| `02-bad-version` | Unsupported `config_version` |
| `03-missing-required` | Missing required keys |
| `10-helper-failure` | Failing `imager_custom` wrapper |
| `20-runcmd-timeout` | Early runcmd timeout |
| `21-runcmd-retry` | Late runcmd retry/backoff |
| `30-power-cut` | Kill QEMU mid-apply, recovery boot |
| `40-network-partition` | No NIC |
| `50-readonly-boot` | Read-only config skips secret redaction |

## Troubleshooting

- **Preflight fails**: install packages listed above.
- **TCG fallback**: need aarch64 host + `/dev/kvm` for KVM.
- **No probe results**: `$RPI_PRESEED_QEMU_WORK/run/<scenario>/serial.log`.
- **Guest dbus/zram storm**: provisioning masks Pi swap/zram/USB/EEPROM units under virt; re-provision if using an old cached `provisioned.qcow2`.
- **Rootfs full / resize2fs**: grow needs `sudo losetup`+`resize2fs` (fuse2fs cannot expand); delete `grown.stamp` and re-prepare if needed.
- **Leaked FUSE mounts**: harness cleans stale `qemu-storage-daemon`/`fuse2fs` at start; if provision fails instantly, kill leftover FUSE processes.
