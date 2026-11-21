#!/usr/bin/python3
"""Volatile, public-only conditions shared by device packages."""
import argparse
import html
import importlib.machinery
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import textwrap

INPUT = Path('/run/ceralive/attention')
OUTPUT = Path('/run/ceralive/attention-status')
SEVERITY = {'info': 0, 'warn': 1, 'critical': 2, 'fatal': 3}
IDENTIFIER = re.compile(r'[a-z][a-z0-9-]{0,63}\Z')
LED = '/usr/local/sbin/ceralive-led-status'
STATUS_SCREEN = Path('/usr/libexec/ceralive/ceralive-status-screen')
ATTENTION_FONT = '/usr/share/consolefonts/Lat15-TerminusBold32x16.psf.gz'
# 8x16 gives 128x37 cells on a 1024x600 panel: room for the text and the QR code.
STATUS_FONT = '/usr/share/consolefonts/Lat15-TerminusBold16.psf.gz'
DRM = Path('/sys/class/drm')


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name('.' + path.name + '.' + str(os.getpid()))
    try:
        temp.write_text(value)
        temp.chmod(0o644)
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


def validate(item, now):
    if not isinstance(item, dict) or not IDENTIFIER.fullmatch(item.get('id', '')):
        raise ValueError('invalid id')
    if item.get('severity') not in SEVERITY:
        raise ValueError('invalid severity')
    for key, limit in [('line', 120), ('detail', 2000), ('fix', 500)]:
        value = item.get(key)
        if not isinstance(value, str) or not value or len(value) > limit:
            raise ValueError('invalid text')
        if any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError('control character')
    expiry = item.get('expires')
    if isinstance(expiry, bool) or not isinstance(expiry, (int, float)) or not math.isfinite(expiry):
        raise ValueError('invalid expiry')
    if not now < expiry <= now + 86400:
        raise ValueError('expired or excessive lifetime')
    if item.get('led', 'auto') not in ('auto', 'none'):
        raise ValueError('invalid LED hint')
    return {key: item[key] for key in ('id', 'severity', 'line', 'detail', 'fix', 'expires')} | {'led': item.get('led', 'auto')}


def conditions(directory=INPUT, now=None):
    now = time.time() if now is None else now
    result = []
    for path in directory.glob('*.json'):
        try:
            if path.is_symlink() or path.stat().st_size > 8192:
                continue
            item = validate(json.loads(path.read_text()), now)
            if path.name == item['id'] + '.json':
                result.append(item)
        except (OSError, ValueError, TypeError):
            continue
    return sorted(result, key=lambda item: (-SEVERITY[item['severity']], item['id']))


def render(items, directory=OUTPUT):
    top = items[0] if items else None
    title = top['line'] if top else 'No attention conditions reported.'
    body = '<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content="width=device-width"><title>Device status</title>'
    body += ("<p>The box can't start safely.</p>" if top and top['id'] == 'data-readiness' else '')
    body += '<h1>' + html.escape(title) + '</h1>'
    if top:
        body += '<p>' + html.escape(top['fix']) + '</p><details><summary>Details</summary><p>' + html.escape(top['detail']) + '</p></details>'
    body += '<p>This page reports device conditions. It does not report stream status.</p></html>'
    atomic(directory / 'index.html', body)
    atomic(directory / 'status.json', json.dumps({'conditions': items, 'highest': top}))
    return top


def command(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=3, check=False).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ''


def publish(identifier, severity, line, detail, fix, ttl=30):
    item = dict(id=identifier, severity=severity, line=line, detail=detail, fix=fix,
                expires=time.time() + ttl)
    item = validate(item, time.time())
    atomic(INPUT / (identifier + '.json'), json.dumps(item))


def data_condition(receipt=Path('/run/ceralive-data-status')):
    try:
        reason, media, partition, filesystem, available = receipt.read_text().split()
    except (OSError, ValueError):
        (INPUT / 'data-readiness.json').unlink(missing_ok=True)
        return
    messages = {
        'media-too-small': ('This card is too small for the box.', 'Use a card sold as 16 GB or bigger. Set it up with the image again.'),
        'card-read-only': ('This card is read-only.', 'Check the adapter lock. If the card stays read-only, set up a different card.'),
        'card-io-failed': ("The box couldn't prepare its storage.", "Use local recovery to check the filesystem or set up the card with the image again. If failures persist, set up a different card."),
        'data-full': ('The card does not have enough free space.', 'Use local recovery to free space, then restart the device.'),
        'partition-growth': ('The card could not finish getting ready.', 'Use local recovery to check the card, then restart the device.'),
        'filesystem-growth': ('The card could not finish getting ready.', 'Use local recovery to check the card, then restart the device.'),
        'filesystem-incomplete': ('The card could not finish getting ready.', 'Use local recovery to check the card, then restart the device.'),
    }
    line, fix = messages.get(reason, ('The card is not ready to use safely.', 'Use local recovery to check the card, then restart the device.'))
    if reason not in messages:
        reason = 'data-unusable'
    sizes = [v if re.fullmatch(r'[0-9]{1,20}', v) else 'unknown' for v in (media, partition, filesystem, available)]
    detail = 'Reason: {}. Media bytes: {}; data partition bytes: {}; filesystem bytes: {}; available bytes: {}. Current image minimum media: 15000000000 bytes. A card sold as 16 GB holds a little under 16 GB, which is normal and passes; minimum available: 1073741824 bytes.'.format(reason, *sizes)
    publish('data-readiness', 'fatal', line, detail, fix)


def probes(thermal=Path('/sys/class/thermal')):
    data_condition()
    if not Path('/run/ceralive-data-status').exists() and (command('systemctl', 'is-failed', 'ceralive-data-ready.service') == 'failed' or any(command('systemctl', 'is-failed', unit) == 'failed' for unit in ('ceralive-grow-data.service', 'systemd-growfs@data.service', 'data.mount'))):
        publish('data-readiness', 'fatal', 'The card is not ready to use safely.',
                'The storage readiness check failed or timed out.',
                'Use local recovery to check the card, then restart the device.')
    # No clock correctness claim: only an obviously unset date is detected.
    if time.time() < 1735689600:
        publish('clock-unset', 'warn', 'The device clock is not set.', 'Secure connections may fail until the clock is set.', 'Connect to a network with time service or set the clock locally.')
    for path in thermal.glob('thermal_zone*/temp'):
        try:
            temperature = int(path.read_text())
            if temperature >= 85000:
                publish('temperature-high', 'critical', 'The device temperature is high.', 'A temperature sensor reports at least 85 C.', 'Improve airflow and check the fan. Let the device cool.')
                break
        except (OSError, ValueError):
            pass


def console_command(*args):
    try:
        subprocess.run(args, capture_output=True, timeout=3, check=True)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def hdmi_connected(drm=DRM):
    """Names of the HDMI connectors that report a monitor.

    The kernel updates this attribute in the same hotplug path that sends the
    drm change uevent, so reading it every watch tick sees the same events.
    """
    found = set()
    for path in drm.glob('card*-HDMI-A-*/status'):
        try:
            if path.read_text().strip() == 'connected':
                found.add(path.parent.name)
        except OSError:
            pass
    return found


def operator_on(vt, proc=Path('/proc')):
    """True when anything but a login prompt runs on tty<vt>: someone is logged in."""
    if not vt.isdecimal():
        return False
    device = (4 << 8) | int(vt)  # tty_nr of /dev/tty<vt> (major 4) in /proc/<pid>/stat
    for path in proc.glob('[0-9]*/stat'):
        try:
            text = path.read_text()
            name = text[text.index('(') + 1:text.rindex(')')]
            terminal = int(text[text.rindex(')') + 2:].split()[4])
        except (OSError, ValueError, IndexError):
            continue
        if terminal == device and name not in ('agetty', 'login'):
            return True
    return False


class StatusPage:
    """The status screen renderer, run in this process; None when not installed."""

    def __init__(self, module):
        self.module = module
        self.code = (None, None)  # last URL and its QR matrix; qrencode runs on change only

    @classmethod
    def load(cls, path=STATUS_SCREEN):
        if not path.exists():
            return None
        sys.dont_write_bytecode = True  # never write a cache next to the image's tools
        loader = importlib.machinery.SourceFileLoader('ceralive_status_screen', str(path))
        module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        loader.exec_module(module)
        return cls(module)

    def qr(self, url):
        if self.code[0] != url or self.code[1] is None:
            self.code = (url, self.module.qr_matrix(url))
        return self.code[1]

    def __call__(self, columns, rows):
        m = self.module
        return m.page_lines(m.facts(), m.load_snapshot(), columns, rows, qr=self.qr)

    def console(self, line):
        return self.module.to_console([line])


class Console:
    """Own only VT8; leave the login terminals and their fonts untouched.

    With the status screen installed VT8 always shows something: the highest
    critical or fatal condition in the large font, else the status page in the
    8x16 font. Without it VT8 is only taken for critical and fatal conditions.
    """

    def __init__(self, directory=Path('/run/ceralive/attention-console'), terminal='/dev/tty8',
                 run=console_command, foreground=None, status=None, connectors=hdmi_connected,
                 operator=operator_on):
        self.directory = directory
        self.terminal = terminal
        self.run = run
        self.foreground = foreground or (lambda: command('fgconsole'))
        self.status = status
        self.connectors = connectors
        self.operator = operator
        self.state = directory / 'state.json'
        self.font = directory / 'font.psf'
        # Survives a service stop: the boot switch happens once per boot.
        self.booted = directory / 'boot-switch-done'
        self.loaded_font = None
        self.seen = None  # HDMI connectors at the previous tick; None until the first look
        # A restarted owner must not pull an operator away from their login.
        self.entered = self.saved().get('alarm', True) if self.state.exists() else False

    def saved(self):
        try:
            value = json.loads(self.state.read_text())
            return value if isinstance(value, dict) else {}
        except (OSError, ValueError):
            return {}

    def save(self, **changes):
        atomic(self.state, json.dumps(self.saved() | changes))

    def acquire(self):
        if self.state.exists():
            return
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        previous = self.foreground()
        if not valid_vt(previous):
            previous = '1'
        # Persist the return VT before changing either font or foreground VT.
        atomic(self.state, json.dumps({'return_vt': previous, 'alarm': False, 'pulled': False}))
        # Never change the font unless its original bytes were saved successfully.
        temporary_font = self.directory / 'font.tmp'
        temporary_font.unlink(missing_ok=True)
        if self.run('setfont', '-C', self.terminal, '-O', str(temporary_font)) and temporary_font.exists():
            temporary_font.replace(self.font)
        else:
            temporary_font.unlink(missing_ok=True)

    def use_font(self, path):
        if self.loaded_font != path and self.font.exists() and self.run('setfont', '-C', self.terminal, path):
            self.loaded_font = path

    def update(self, top):
        alarm = bool(top) and top['severity'] in ('critical', 'fatal')
        if not alarm and self.status is None:
            self.release()
            return
        self.acquire()
        if not alarm and self.entered:
            self.end_alarm()
        self.use_font(ATTENTION_FONT if alarm else STATUS_FONT)
        try:
            with open(self.terminal, 'w') as terminal:
                try:
                    columns, rows = os.get_terminal_size(terminal.fileno())
                except OSError:
                    columns, rows = 80, 25
                columns, rows = max(20, columns), max(5, rows)
                terminal.write(self.alarm_text(top, columns, rows) if alarm else self.status_text(columns, rows))
            if alarm and not self.entered:
                previous = self.foreground()
                if valid_vt(previous):
                    # Taken from another VT: hand it back when the condition clears.
                    self.save(return_vt=previous, pulled=True)
                self.save(alarm=True)
                self.entered = self.run('chvt', '8')
        except OSError:
            return
        if self.status is not None:
            self.follow_monitor()

    def alarm_text(self, top, columns, rows):
        lines = []
        heading = "The box can't start safely. " if top['id'] == 'data-readiness' else ''
        for value in (heading + top['line'], '', top['fix'], '', 'Details: ' + top['detail']):
            lines.extend(textwrap.wrap(value, width=columns) or [''])
        # Keep the recovery shortcut visible even for very long details.
        lines = lines[:rows - 4]
        lines += ['', 'Alt+F1 to log in. Alt+F8 returns here.']
        return '\033[2J\033[H\033[?25l' + '\n'.join(lines) + '\n'

    def status_text(self, columns, rows):
        try:
            lines = self.status(columns, rows)
            painted = [self.status.console(line) for line in lines]
        except Exception:  # A renderer fault must never stop the attention owner.
            lines = painted = ['Box status is not available.', 'Alt+F1 to log in.']
        # Overwrite in place, without clearing first, so a phone camera sees no flicker.
        # The page ends without a newline so the first row never scrolls away.
        text = '\033[H\033[?25l' + '\n'.join('\033[2K' + line for line in painted)
        # Erase what is left below, unless the cursor already sits in the last column.
        return text + ('\033[J' if len(lines[-1]) < columns else '')

    def end_alarm(self):
        """The condition is gone: return an operator it pulled away, then show the status page."""
        state = self.saved()
        if state.get('pulled') and self.foreground() == '8':
            previous = state.get('return_vt')
            if not self.run('chvt', previous if valid_vt(previous) else '1'):
                return  # Retry next tick; VT8 still shows something useful.
        self.save(alarm=False, pulled=False)
        self.entered = False

    def follow_monitor(self):
        """Show VT8 once per boot and when a monitor is plugged in, unless someone is logged in."""
        connected = self.connectors()
        plugged = self.seen is not None and bool(connected - self.seen)
        self.seen = connected
        boot = not self.booted.exists()
        if not (boot or plugged):
            return
        current = self.foreground()
        if current == '8' or self.operator(current) or self.run('chvt', '8'):
            if boot:
                atomic(self.booted, '')

    def release(self):
        if not self.state.exists():
            return
        try:
            previous = json.loads(self.state.read_text())['return_vt']
            if not valid_vt(previous):
                previous = '1'
            # Return to the untouched login before clearing our screen. A font
            # failure must not strand the operator on an empty diagnostic VT.
            if self.foreground() == '8' and not self.run('chvt', previous):
                return
            with open(self.terminal, 'w') as terminal:
                terminal.write('\033[2J\033[H\033[?25h')
            if self.font.exists() and not self.run('setfont', '-C', self.terminal, str(self.font)):
                return  # The private backup survives even a manual service stop.
            self.font.unlink(missing_ok=True)
            self.state.unlink()
            self.entered = False
            self.loaded_font = None
        except (OSError, ValueError, KeyError, TypeError):
            pass


def valid_vt(value):
    return isinstance(value, str) and value.isdecimal() and 1 <= int(value) <= 63 and value != '8'


def apply(top):
    command(LED, 'attention', top['severity'] if top and top['led'] != 'none' else 'clear')


def listener(items):
    # Fallback only when the backend and provisioning are absent. Never
    # stop a running application just to display an attention condition.
    ui = command('systemctl', 'is-active', 'ceralive.service')
    portal = command('systemctl', 'is-active', 'ceralive-portal.socket')
    if any(i['id'] == 'data-readiness' for i in items) and ui in ('failed', 'inactive') and portal in ('inactive', 'failed'):
        command('systemctl', '--no-block', 'start', 'ceralive-data-diagnostic.socket')
    else:
        command('systemctl', '--no-block', 'stop', 'ceralive-data-diagnostic.socket')


def watch():
    previous = None
    try:
        status = StatusPage.load()
    except Exception:  # A broken renderer leaves VT8 to critical and fatal conditions only.
        status = None
    console = Console(status=status)
    running = True
    def stop(*_):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while running:
            probes()
            items = conditions()
            # Expiry refreshes alone need no visible repaint.
            signature = [{k: v for k, v in item.items() if k != 'expires'} for item in items]
            top = render(items)
            if signature != previous:
                apply(top)
                previous = signature
            # Repaint the dedicated VT even when the condition is unchanged,
            # without switching back when the operator chooses a login VT.
            console.update(top)
            listener(items)
            time.sleep(2)
    finally:
        console.release()
        command(LED, 'attention', 'clear')
        command('systemctl', '--no-block', 'stop', 'ceralive-data-diagnostic.socket')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('watch')
    clear = sub.add_parser('clear')
    clear.add_argument('id')
    post = sub.add_parser('post')
    for field in ('id', 'severity', 'line', 'detail', 'fix'):
        post.add_argument(field)
    post.add_argument('--ttl', type=int, default=30)
    args = parser.parse_args()
    if args.action == 'watch':
        watch()
    elif args.action == 'clear':
        if not IDENTIFIER.fullmatch(args.id):
            parser.error('invalid id')
        (INPUT / (args.id + '.json')).unlink(missing_ok=True)
    else:
        publish(args.id, args.severity, args.line, args.detail, args.fix, args.ttl)


if __name__ == '__main__':
    main()
