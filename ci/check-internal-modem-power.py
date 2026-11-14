#!/usr/bin/env python3
"""Keep image-owned runtime free of unreviewed modem rail control."""
import pathlib
import re
import sys

# The image installs uhubctl for manual external-USB maintenance, but no runtime
# service is allowed to invoke it (the internal slot is not USB VBUS powered).
command = re.compile(
    r'\b(?:gpioset|uhubctl)\b|\bgpiod\b|/dev/gpiochip'
    r'|/sys/(?:class/gpio|class/regulator|kernel/debug/regulator)'
    r'|/sys/bus/usb/devices/[^\s"\x27]*port[^\s"\x27]*/disable'
    r'|/sys/bus/platform/drivers/reg-fixed-voltage/'
)
violations = []
for path in pathlib.Path(sys.argv[1]).rglob('*'):
    if not path.is_file():
        continue
    data = path.read_bytes()
    if b'\0' in data:  # Binary assets are not executable text policy.
        continue
    for number, line in enumerate(data.decode('utf-8', errors='replace').splitlines(), 1):
        if line.lstrip().startswith('#'):
            continue
        if command.search(line):
            violations.append(f'{path.name}:{number}: power control requires a reviewed FULL_CARD_POWER_OFF# boundary')
if violations:
    sys.exit('\n'.join(violations))
print('No image-owned modem slot/rail power-cycle path')
