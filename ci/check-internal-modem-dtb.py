#!/usr/bin/env python3
"""Check a compiled ROCK 5B+ board DTB for the B-key slot contract.

The slot power order now comes from the boot script (EKEY_EN held low until Linux),
so the kernel DT must keep the base sequence: the RESET# hog releases reset at GPIO
bank probe, the 3.3 V supplies are always-on and handed over enabled, and the
retired 0052 off-on delay on FULL_CARD_POWER_OFF# (pin 6) is absent. W_DISABLE1#
stays owned by rfkill-gpio.

Usage: check-internal-modem-dtb.py <rk3588-rock-5b-plus.dtb>
"""
import re
import subprocess
import sys


def nodes(dts):
    """Yield (name, body) for every node at any depth that has no child nodes."""
    for match in re.finditer(r'([\w@,.-]+) \{\n((?:\t[^\n{}]*\n)*?)\t*\};', dts):
        yield match.group(1), match.group(2)


def find(dts, predicate, what):
    found = [body for name, body in nodes(dts) if predicate(name, body)]
    assert len(found) == 1, f'expected one {what}, found {len(found)}'
    return found[0]


def main(path):
    dts = subprocess.check_output(['dtc', '-q', '-I', 'dtb', '-O', 'dts', path], text=True)
    wwan = find(dts, lambda n, b: 'regulator-name = "vcc3v3_wwan_pwr";' in b, 'vcc3v3_wwan_pwr regulator')
    assert 'off-on-delay-us' not in wwan, 'vcc3v3_wwan_pwr carries the retired 0052 off-on delay'
    assert 'regulator-always-on;' in wwan and 'regulator-boot-on;' in wwan, \
        'vcc3v3_wwan_pwr must stay always-on and boot-on (no FULL_CARD_POWER_OFF# toggle at probe)'
    rail = find(dts, lambda n, b: 'regulator-name = "vcc3v3_4g";' in b, 'vcc3v3_4g regulator')
    assert 'regulator-always-on;' in rail, 'vcc3v3_4g must come back on in Linux after the boot-script hold'
    assert re.search(r'gpios = <0x[0-9a-f]+ 0x1a 0x00>;', rail), 'vcc3v3_4g is no longer EKEY_EN (GPIO1_D2)'
    reset = find(dts, lambda n, b: 'line-name = "M.2 B-key RESET#";' in b, 'RESET# hog')
    assert 'gpio-hog;' in reset and 'gpios = <0x0b 0x01>;' in reset and 'output-low;' in reset, \
        'RESET# hog must drive GPIO2_B3 active-low output-low (reset released) at bank probe'
    rfkill = find(dts, lambda n, b: 'label = "rfkill-m2-wwan";' in b, 'rfkill-m2-wwan node')
    assert 'compatible = "rfkill-gpio";' in rfkill and 'default-blocked' not in rfkill
    assert re.search(r'shutdown-gpios = <0x[0-9a-f]+ 0x06 0x00>;', rfkill), 'W_DISABLE1# pin or polarity changed'
    print('board DTB: base B-key sequence, no 0052 delay, RESET# hog and rfkill-gpio present')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
