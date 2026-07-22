# rpi-preseed — build/install/test

DESTDIR ?=
PREFIX  ?= /usr
LIBDIR   = $(PREFIX)/lib/rpi-preseed
SHAREDIR = $(PREFIX)/share/rpi-preseed
BINDIR   = $(PREFIX)/bin
MANDIR   = $(PREFIX)/share/man/man5
DOCDIR   = $(PREFIX)/share/doc/rpi-preseed
UNITDIR  = /lib/systemd/system

SCRIPTS = $(wildcard src/lib/*.sh) $(wildcard src/apply/*.sh) src/rpi-preseed
QEMU_SCRIPTS = $(wildcard tests/qemu/lib/*.sh) tests/qemu/run.sh tests/qemu/probe/collect.sh \
	$(wildcard tests/qemu/scenarios/*/fault.sh) $(wildcard tests/qemu/scenarios/*/expect.sh)

.PHONY: all install check test shellcheck clean qemu-check qemu-list qemu-download

all:
	@echo "Nothing to build (POSIX shell). Try: make check | make install"

install:
	install -d $(DESTDIR)$(LIBDIR)/lib $(DESTDIR)$(LIBDIR)/apply
	install -m 0755 src/rpi-preseed $(DESTDIR)$(LIBDIR)/rpi-preseed
	install -m 0644 src/lib/*.sh $(DESTDIR)$(LIBDIR)/lib/
	install -m 0644 src/apply/*.sh $(DESTDIR)$(LIBDIR)/apply/
	install -d $(DESTDIR)$(BINDIR)
	ln -sf $(LIBDIR)/rpi-preseed $(DESTDIR)$(BINDIR)/rpi-preseed
	install -d $(DESTDIR)$(SHAREDIR)
	install -m 0644 schema/rpi-preseed.schema $(DESTDIR)$(SHAREDIR)/
	install -d $(DESTDIR)$(UNITDIR) $(DESTDIR)$(UNITDIR)/user@.service.d
	install -m 0644 systemd/*.service systemd/*.target $(DESTDIR)$(UNITDIR)/
	install -m 0644 systemd/user@.service.d/10-rpi-preseed.conf $(DESTDIR)$(UNITDIR)/user@.service.d/
	install -d $(DESTDIR)$(MANDIR)
	install -m 0644 doc/rpi-preseed.5 $(DESTDIR)$(MANDIR)/
	install -d $(DESTDIR)$(DOCDIR)/examples
	install -m 0644 examples/rpi-preseed.toml $(DESTDIR)$(DOCDIR)/examples/

check: shellcheck test

shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed; skipping"; exit 0; }
	shellcheck -x $(SCRIPTS) tests/run.sh tests/test_toml.sh tests/test_validate.sh tests/test_redact.sh tests/test_hash.sh tests/test_integration.sh
	shellcheck -x $(QEMU_SCRIPTS)
	@echo "shellcheck OK"

test:
	@sh tests/run.sh

qemu-check:
	@sh tests/qemu/run.sh

qemu-download:
	@sh tests/qemu/run.sh --download-only

qemu-list:
	@ls -1 tests/qemu/scenarios

clean:
	@rm -f tests/*.log
