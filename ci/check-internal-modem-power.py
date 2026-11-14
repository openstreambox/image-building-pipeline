#!/usr/bin/env python3
"""Keep image-owned runtime free of unreviewed modem rail control."""
import pathlib
import re
import sys

# The image installs uhubctl for manual external-USB maintenance, but no runtime
# service is allowed to invoke it (the internal slot is not USB VBUS powered).
command = re.compile(r'\b(?:gpioset|uhubctl)\b|/sys/(?:class/gpio|class/regulator|kernel/debug/regulator)')
violations = []
for directory in ('runtime', 'customize', 'mkosi.images/runtime'):
    for path in (pathlib.Path(sys.argv[1]) / directory).rglob('*'):
        if not path.is_file() or path.suffix not in ('.sh', '.service', '.rules', '.chroot', '.conf'):
            continue
        for number, line in enumerate(path.read_text(errors='replace').splitlines(), 1):
            if line.lstrip().startswith('#'):
                continue
            if command.search(line):
                violations.append(f'{path.name}:{number}: power control requires a reviewed FULL_CARD_POWER_OFF# boundary')
if violations:
    sys.exit('\n'.join(violations))
print('No image-owned modem slot/rail power-cycle path')
