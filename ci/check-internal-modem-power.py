#!/usr/bin/env python3
"""Keep image-owned runtime free of unreviewed modem rail control."""
import pathlib
import re
import subprocess
import sys

# The image installs uhubctl for manual external-USB maintenance, but no runtime
# service is allowed to invoke it (the internal slot is not USB VBUS powered).
command = re.compile(
    r'\b(?:gpioset|uhubctl)\b|\bgpiod\b|/dev/gpiochip'
    r'|/sys/(?:class/gpio|class/regulator|kernel/debug/regulator)'
    r'|/sys/bus/usb/devices/[^\s"\x27]*port[^\s"\x27]*/disable'
    r'|/sys/bus/platform/drivers/reg-fixed-voltage/'
    # U-Boot's gpio command in a boot script.
    r'|(?:^|[\s;])(?:if\s+)?gpio\s+(?:set|clear|toggle)\b'
    # De-authorizing or resetting a USB device: the slot Dell's fastboot endpoint
    # stops answering after either, so no image code may do it.
    r'|/authorized\b|USBDEVFS_RESET|0x5514\b'
)
# The one reviewed boundary: the boot script holds EKEY_EN low before Linux on the
# ROCK 5B+ (docs/rock5bplus-internal-modem.md). It must stay this exact line, in
# this file only.
REVIEWED = {('boot.scr.cmd', '  if gpio clear B26; then setenv cera_slot_power "held"; fi')}

def candidates(root):
    """Tracked files when root is in a Git work tree (a built tree also holds root-owned
    mkosi output and caches that are not image sources); every file otherwise."""
    listing = subprocess.run(['git', '-C', str(root), 'ls-files', '-z', '--', '.'],
                             capture_output=True, check=False)
    if listing.returncode == 0:
        return [root / name for name in listing.stdout.decode().split('\0') if name]
    return [path for path in root.rglob('*') if path.is_file()]


violations = []
for path in candidates(pathlib.Path(sys.argv[1])):
    if not path.is_file():
        continue
    data = path.read_bytes()
    if b'\0' in data:  # Binary assets are not executable text policy.
        continue
    for number, line in enumerate(data.decode('utf-8', errors='replace').splitlines(), 1):
        if line.lstrip().startswith('#'):
            continue
        if command.search(line) and (path.name, line) not in REVIEWED:
            violations.append(f'{path.name}:{number}: power control requires a reviewed FULL_CARD_POWER_OFF# boundary')
if violations:
    sys.exit('\n'.join(violations))
print('No image-owned modem slot/rail power-cycle path beyond the reviewed boot-script hold')
