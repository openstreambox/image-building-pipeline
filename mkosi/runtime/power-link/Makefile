CC ?= cc
CFLAGS ?= -O2
WARNINGS = -std=c11 -Wall -Wextra -Werror
DESTDIR ?=

.PHONY: all check install clean
all: osb-power-link
osb-power-link: power_link.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) $(LDFLAGS) -o $@ $<
test-power-link: test_power_link.c power_link.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) $(LDFLAGS) -o $@ test_power_link.c
check: test-power-link
	./test-power-link
	@if [ "$$(uname -s)" = Linux ]; then python3 test_service.py; else echo "Linux service tests require Linux"; fi
install: osb-power-link
	install -D -m 0755 osb-power-link $(DESTDIR)/usr/libexec/osb-power-link
	install -D -m 0644 osb-power-link.service $(DESTDIR)/usr/lib/systemd/system/osb-power-link.service
	install -D -m 0644 osb-power-tmpfiles.conf $(DESTDIR)/usr/lib/tmpfiles.d/osb-power.conf
	install -D -m 0644 osb-power.conf $(DESTDIR)/usr/lib/sysusers.d/osb-power.conf
	install -D -m 0644 79-osb-supervisor.rules $(DESTDIR)/usr/lib/udev/rules.d/79-osb-supervisor.rules
	systemctl $(if $(DESTDIR),--root="$(DESTDIR)") enable osb-power-link.service
clean:
	rm -f osb-power-link test-power-link
