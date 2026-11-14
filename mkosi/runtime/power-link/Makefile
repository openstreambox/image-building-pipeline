CC ?= cc
CFLAGS ?= -O2
WARNINGS = -std=c11 -Wall -Wextra -Werror
DESTDIR ?=

.PHONY: all check install clean
all: supervisor-power-link
supervisor-power-link: power_link.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) $(LDFLAGS) -o $@ $<
test-power-link: test_power_link.c power_link.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) $(LDFLAGS) -o $@ test_power_link.c
check: test-power-link
	./test-power-link
	@if [ "$$(uname -s)" = Linux ]; then python3 test_service.py; else echo "Linux service tests require Linux"; fi
install: supervisor-power-link
	install -D -m 0755 supervisor-power-link $(DESTDIR)/usr/libexec/supervisor-power-link
	install -D -m 0644 supervisor-power-link.service $(DESTDIR)/usr/lib/systemd/system/supervisor-power-link.service
	install -D -m 0644 supervisor-power-tmpfiles.conf $(DESTDIR)/usr/lib/tmpfiles.d/supervisor-power.conf
	install -D -m 0644 supervisor-power.conf $(DESTDIR)/usr/lib/sysusers.d/supervisor-power.conf
	install -D -m 0644 79-power-supervisor.rules $(DESTDIR)/usr/lib/udev/rules.d/79-power-supervisor.rules
	systemctl $(if $(DESTDIR),--root="$(DESTDIR)") enable supervisor-power-link.service
clean:
	rm -f supervisor-power-link test-power-link
