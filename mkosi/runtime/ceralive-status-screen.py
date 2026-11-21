#!/usr/bin/python3
"""A plain status page for a monitor on the box, written to be photographed.

Someone holding a box that has no network plugs in any HDMI monitor and sends
a photo to support. The page answers the first support questions without a
login: which image and CeraUI it runs, how long it has been up, which uplinks
and SIMs it sees, whether it is ready to go live and why not, the last error,
the box's support code, and a QR code to its local UI.

Two sources, so the page still says something when the application is down:

- The image's own facts: release, uptime, support code (the same four hex
  digits the setup hotspot and hostname carry), local IPv4 addresses and the
  highest shared attention condition.
- A snapshot CeraUI writes to /run/ceralive/status-screen/snapshot.json. It
  carries codes, role labels and states only, never free text; the page maps
  codes to fixed wording. A snapshot that is missing, oversized, not a regular
  file, malformed or expired is ignored and the page says so.

The page is printable ASCII only, so every console font draws it. The QR code
comes from Debian's `qrencode` and is drawn with reverse-video spaces (two
cells per module, one row per module), so it needs no block glyphs either.
This file only renders; the attention owner decides when VT8 shows it (see
docs/status-screen.md).
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import textwrap
import time
import unicodedata
from urllib.parse import urlsplit

SNAPSHOT = Path('/run/ceralive/status-screen/snapshot.json')
ATTENTION = Path('/run/ceralive/attention-status/status.json')
QRENCODE = os.environ.get('CERALIVE_QRENCODE', '/usr/bin/qrencode')
MAX_SNAPSHOT = 16384
MAX_ENTRIES = 8
QUIET = 4  # light modules on every side, as the QR specification asks
LIGHT = '\x01'  # internal marker for a light QR cell; never survives clean()
FOOTER = 'Photograph this screen for support. Alt+F1 to log in.'
FOOTER_SHORT = 'Alt+F1 to log in.'
CODE = re.compile(r'[A-Za-z0-9_]{1,48}\Z')
# A release version: dotted numbers, at most two short suffixes (no bare digit runs).
VERSION = re.compile(r'\d{1,4}(\.\d{1,4}){1,3}([.+~-][0-9A-Za-z]{1,12}){0,2}\Z')

# Fixed wording for the codes CeraUI's stream-ready flag reports; any other
# code gets fixed generic wording, never its own text.
READY_TEXT = {
    'update_in_progress': 'an update is installing',
    'recovery_pending': 'the box is restoring its last session',
    'mutation_in_progress': 'a modem change is running',
    'MODEM_TRANSITION_ACTIVE': 'a modem is restarting',
    'START_IN_PROGRESS': 'a start is already running',
    'no_source': 'no video source is chosen',
    'unknown_source': 'the video source is gone',
    'source_lost': 'the video source is not connected',
    'source_unavailable': 'the video source is not sending',
    'receiver_not_set': 'no destination is set',
    'receiver_invalid': 'the destination is not available',
    'receiver_refused': 'the destination refused the last test',
    'no_uplink': 'no uplink is connected',
    'no_uplink_passes': 'no uplink reaches the internet',
    'no_link_carrying': 'no link carries the stream',
}
KIND_LABEL = {'cellular': 'Cellular', 'ethernet': 'Ethernet', 'wifi': 'Wi-Fi', 'other': 'Link'}


# --- Text -------------------------------------------------------------------

def clean(value, limit):
    """Printable ASCII only, or None: no controls, escapes, bidi or wide text."""
    if not isinstance(value, str):
        return None
    try:
        value.encode('utf-8')
    except UnicodeEncodeError:  # lone surrogates
        return None
    spaced = ''.join(' ' if unicodedata.category(c)[0] in 'CZ' else c
                     for c in unicodedata.normalize('NFKD', value))
    folded = spaced.encode('ascii', 'ignore').decode('ascii')
    folded = ' '.join(folded.split())
    return folded[:limit] or None


OTHER_REASON = 'another reason (see the support log)'


def code_text(code, table):
    if not isinstance(code, str) or not CODE.fullmatch(code):
        return None
    return table.get(code, OTHER_REASON)


# --- QR code ----------------------------------------------------------------

def qr_matrix(text, run=subprocess.run, binary=None):
    """Module matrix (True = dark) from qrencode, or None when it cannot encode."""
    try:
        out = run([binary or QRENCODE, '-t', 'ASCII', '-m', '0', '-l', 'M', '-8', '--', text],
                  capture_output=True, timeout=5, check=True, text=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    rows = [line for line in out.split('\n') if line]
    if not rows or any(len(row) != 2 * len(rows) or set(row) - {'#', ' '} for row in rows):
        return None
    return [[row[i] == '#' for i in range(0, len(row), 2)] for row in rows]


def qr_cells(matrix, quiet=QUIET):
    """Rows of cells: LIGHT for a light module (quiet zone included), ' ' for dark.

    The console draws LIGHT as reverse-video spaces, so with the usual light
    foreground on a dark background the code reads dark on light.
    """
    size = len(matrix)
    span = size + 2 * quiet
    rows = []
    for y in range(span):
        row = []
        for x in range(span):
            mx, my = x - quiet, y - quiet
            dark = 0 <= mx < size and 0 <= my < size and matrix[my][mx]
            row.append('  ' if dark else LIGHT * 2)
        rows.append(''.join(row))
    return rows


def to_console(lines):
    """Turn LIGHT runs into reverse-video spaces. No trailing newline."""
    return '\n'.join(re.sub(LIGHT + '+', lambda m: '\x1b[7m' + ' ' * len(m.group()) + '\x1b[27m', line)
                     for line in lines)


# --- Inputs -----------------------------------------------------------------

class BadSnapshot(Exception):
    pass


def _reject_constant(name):
    raise BadSnapshot(name)


def read_bounded(path, limit=MAX_SNAPSHOT):
    """Read a regular file without following a symlink or blocking on a FIFO."""
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | getattr(os, 'O_CLOEXEC', 0)
    fd = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise BadSnapshot('not a regular file')
        data = b''
        while len(data) <= limit:
            chunk = os.read(fd, limit + 1 - len(data))
            if not chunk:
                break
            data += chunk
        if len(data) > limit:
            raise BadSnapshot('too large')
        return data
    finally:
        os.close(fd)


def _int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def load_snapshot(path=SNAPSHOT, now=None):
    """CeraUI's report, or None when it cannot be trusted as current."""
    now = time.time() if now is None else now
    try:
        item = json.loads(read_bounded(path).decode('utf-8'), parse_constant=_reject_constant)
    except (OSError, ValueError, BadSnapshot, RecursionError):
        return None
    if not isinstance(item, dict) or not _int(item.get('schema')) or item['schema'] != 2:
        return None
    expires = item.get('expires')
    if not _int(expires) or expires <= now or expires > now + 3600:
        return None
    result = {'ceraui': None, 'url': None, 'uplinks': [], 'modems': []}
    version = item.get('ceraui')
    if isinstance(version, str) and VERSION.fullmatch(version):
        result['ceraui'] = version
    url = item.get('url')
    if isinstance(url, str) and len(url) <= 64:
        result['url'] = url
    counts = {}
    uplinks = item.get('uplinks')
    for entry in uplinks[:MAX_ENTRIES] if isinstance(uplinks, list) else []:
        kind, state = (entry.get('kind'), entry.get('state')) if isinstance(entry, dict) else (None, None)
        if isinstance(kind, str) and kind in KIND_LABEL and isinstance(state, str) and state in ('up', 'degraded', 'down'):
            counts[kind] = counts.get(kind, 0) + 1
            result['uplinks'].append({'name': '%s %d' % (KIND_LABEL[kind], counts[kind]), 'state': state})
    modems = item.get('modems')
    for index, entry in enumerate(modems[:MAX_ENTRIES] if isinstance(modems, list) else []):
        sim = entry.get('sim') if isinstance(entry, dict) else None
        if isinstance(sim, str) and sim in ('present', 'absent', 'locked', 'unknown'):
            result['modems'].append({'name': 'Modem %d' % (index + 1), 'sim': sim})
    ready = item.get('ready')
    if isinstance(ready, dict) and isinstance(ready.get('ready'), bool):
        result['ready'] = {'ready': ready['ready'], 'line': code_text(ready.get('code'), READY_TEXT)}
    error = item.get('last_error')
    if isinstance(error, dict) and code_text(error.get('code'), READY_TEXT):
        result['last_error'] = code_text(error['code'], READY_TEXT)
    return result


def support_code(machine_id=Path('/etc/machine-id')):
    """The last four hex digits of the machine id, as the setup hotspot shows them."""
    try:
        digits = re.sub(r'[^0-9a-f]', '', machine_id.read_text().lower())
    except OSError:
        return None
    return digits[-4:].upper() if len(digits) >= 4 else None


# Interfaces a phone next to the box is likely on come first; uplinks last.
_CLIENT_FIRST = ('ap', 'wlan', 'br', 'eth', 'end', 'enp', 'usb', 'wwan', 'ppp', 'rmnet')


def _rank(iface):
    for i, prefix in enumerate(_CLIENT_FIRST):
        if iface.startswith(prefix):
            return i
    return len(_CLIENT_FIRST)


def ipv4_addresses(run=subprocess.run):
    """[(iface, address)] for global IPv4, client-facing interfaces first."""
    try:
        out = run(['ip', '-j', '-4', 'addr', 'show', 'scope', 'global'], capture_output=True,
                  timeout=3, check=True, text=True).stdout
        found = [(i.get('ifname', ''), a['local']) for i in json.loads(out)
                 for a in i.get('addr_info', []) if isinstance(a.get('local'), str)]
    except (OSError, ValueError, subprocess.SubprocessError, TypeError, KeyError, AttributeError):
        return []
    found = [(clean(iface, 16) or '', addr) for iface, addr in found if _is_ipv4(addr)]
    return sorted(found, key=lambda pair: _rank(pair[0]))[:4]


def _is_ipv4(addr):
    try:
        ipaddress.IPv4Address(addr)
        return True
    except ValueError:
        return False


def ui_url(snapshot_url, addresses):
    """The QR target, always the image's TLS front: https://<address>/.

    The snapshot may only pick which of the box's own addresses to show; its
    scheme, port and path are not used.
    """
    local = [addr for _, addr in addresses]
    if isinstance(snapshot_url, str) and not re.search(r'[@?#\\]', snapshot_url):
        try:
            host = urlsplit(snapshot_url).hostname
        except ValueError:
            host = None
        if host in local:
            return 'https://%s/' % host
    return 'https://%s/' % local[0] if local else None


def facts(now=None):
    now = time.time() if now is None else now
    try:
        uptime = float(Path('/proc/uptime').read_text().split()[0])
    except (OSError, ValueError, IndexError):
        uptime = None
    try:
        attention = json.loads(read_bounded(ATTENTION).decode('utf-8'),
                               parse_constant=_reject_constant).get('highest')
    except (OSError, ValueError, AttributeError, BadSnapshot, RecursionError):
        attention = None
    image = None
    try:
        for line in Path('/etc/os-release').read_text().splitlines():
            key, _, value = line.partition('=')
            if key in ('IMAGE_VERSION', 'VERSION_ID') and (image is None or key == 'IMAGE_VERSION'):
                image = clean(value.strip('"'), 40)
    except OSError:
        pass
    return {
        'image': image,
        'uptime': uptime,
        'code': support_code(),
        'addresses': ipv4_addresses(),
        'attention': clean(attention.get('line'), 120) if isinstance(attention, dict) else None,
        'now': now,
    }


# --- Page -------------------------------------------------------------------

def _duration(seconds):
    if seconds is None:
        return 'unknown'
    minutes = int(seconds // 60)
    if minutes < 60:
        return '%d min' % minutes
    hours, minutes = divmod(minutes, 60)
    if hours < 48:
        return '%d h %02d min' % (hours, minutes)
    return '%d days %d h' % divmod(hours, 24)


def page_lines(f, snapshot, columns=80, rows=25, qr=qr_matrix):
    """The page as at most `rows` lines of at most `columns` cells; the login line is last."""
    columns, rows = max(1, columns), max(1, rows)
    footer = FOOTER if len(FOOTER) <= columns else FOOTER_SHORT[:columns]
    body_rows = rows - 1
    url = ui_url((snapshot or {}).get('url'), f.get('addresses') or [])
    matrix = qr(url) if url else None
    code = qr_cells(matrix) if matrix else []
    code_width = len(code[0]) if code else 0

    def text_lines(width):
        out = []
        def add(label, value):
            out.extend(textwrap.wrap('%-9s %s' % (label, value), width=width,
                                     subsequent_indent=' ' * 10) or [''])
        out.extend(textwrap.wrap('BOX STATUS  support code %s' % (f.get('code') or '----'), width=width))
        # Where to connect comes first, so crowded detail below is cut instead.
        if url:
            add('Open', url)
        add('Address', ', '.join(addr for _, addr in f.get('addresses') or []) or 'no local address')
        ready = (snapshot or {}).get('ready')
        if ready:
            add('Ready', 'yes' if ready['ready'] else 'no: ' + (ready['line'] or 'reason not given'))
        add('Image', f.get('image') or 'unknown')
        add('CeraUI', (snapshot or {}).get('ceraui') or ('not reporting' if snapshot is None else 'unknown'))
        add('Up for', _duration(f.get('uptime')))
        if snapshot is None:
            add('Status', 'the application has not reported; box facts only')
        else:
            add('Uplinks', ', '.join('%s %s' % (u['name'], u['state']) for u in snapshot['uplinks']) or 'none')
            add('SIMs', ', '.join('%s: SIM %s' % (m['name'], m['sim']) for m in snapshot['modems']) or 'no modem')
            add('Last err', snapshot.get('last_error') or 'none')
        if f.get('attention'):
            add('Attention', f['attention'])
        return out

    # Beside the facts when there is room for both, else below them, else none.
    if code and columns >= code_width + 2 + 30 and body_rows >= len(code):
        width = min(60, columns - code_width - 2)
        text = text_lines(width)[:body_rows]
        body = [(text[i] if i < len(text) else '').ljust(width) + '  ' + (code[i] if i < len(code) else '')
                for i in range(max(len(text), len(code)))]
        body = [line.rstrip(' ') for line in body]
    else:
        text = text_lines(columns)
        if code and code_width <= columns and len(text) + 1 + len(code) <= body_rows:
            body = text + [''] + code
        else:
            body = text[:body_rows]
    return [line[:columns] for line in body[:body_rows]] + [footer]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='action', required=True)
    render = sub.add_parser('render', help='print the page to stdout')
    render.add_argument('--columns', type=int)
    render.add_argument('--rows', type=int)
    render.add_argument('--snapshot', type=Path, default=SNAPSHOT)
    args = parser.parse_args(argv)
    size = os.get_terminal_size() if sys.stdout.isatty() else os.terminal_size((80, 25))
    lines = page_lines(facts(), load_snapshot(args.snapshot), args.columns or size.columns,
                       args.rows or size.lines)
    sys.stdout.write(to_console(lines))
    if not sys.stdout.isatty():
        sys.stdout.write('\n')
    sys.stdout.flush()
    return 0


if __name__ == '__main__':
    sys.exit(main())
