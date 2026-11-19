#!/usr/bin/env python3
"""Differential preset cases for tests/release-preset.bats.

release-preset-cases.py <out dir>

Writes one preset directory per case (update-settings.json +
update-image-channel.json) and prints "<name> <ceraui verdict>" lines, where the
verdict (accept/reject) was measured by running CeraUI's own loader
(loadUpdateSettings + updateChannelUrl at osb-int-20261118.2) on the same files
in an independent review. The host validator must reject every case CeraUI
rejects; it may also reject cases CeraUI accepts (it checks a strict subset).
"""
import json, os, sys
root = sys.argv[1]
base_settings = {"packagesAuto": False, "systemAuto": False, "channel": "stable",
                 "allowPackagesOverCellular": True, "allowSystemOverCellular": False}
base_side = {"schema": 1, "channelUrl": "https://updates.example.org", "channel": "stable",
             "allowSystemDownloadsOverCellular": False}
CERAUI = {
 "00-baseline": True,
 "01-sched-newline": False,
 "02-sched-arabic-digits": False,
 "03-sched-fullwidth-digits": False,
 "10-url-dotdot": False,
 "11-url-dot": False,
 "12-url-port-big": False,
 "13-url-port-alpha": False,
 "14-url-space-host": False,
 "15-url-backslash-tail": False,
 "16-url-pct2e": True,
 "17-url-tab": True,
 "18-url-lead-space": True,
 "19-url-trail-nl": True,
 "20-url-backslash-host": True,
 "21-url-bad-punycode": False,
 "22-url-empty-query": True,
 "23-url-empty-userinfo": True,
 "24-url-root-slash": True,
 "25-url-pct-host": True,
 "26-url-ipv4-hex": True,
 "27-url-bad-ipv4": False,
 "28-url-forbidden-host-char": False,
 "29-url-no-host-slashes": True,
 "30-url-triple-slash": True,
 "31-url-upper-scheme": True,
 "32-url-dot-pct-tail": False,
 "33-url-percent-in-host-bad": False,
 "34-url-pipe-host": False,
 "35-url-ipv6-zone": False,
 "36-url-c0-in-path": True,
 "40-schema-float": True,
 "41-bom": False,
 "42-settings-channelUrl": True,
 "43-proto-key": False,
 "44-escaped-dup": False,
 "45-nan-schema": False,
 "46-big-ws": True,
 "47-schema-1e0": True,
 "48-sched-empty": True,
 "49-sched-window-only-start": True,
 "50-sched-null": False,
 "51-lone-surrogate-key": False
}
cases = {}
def case(name, settings=None, side=None, raw_settings=None, raw_side=None):
    s = raw_settings if raw_settings is not None else json.dumps(settings if settings is not None else base_settings)
    c = raw_side if raw_side is not None else json.dumps(side if side is not None else base_side)
    cases[name] = (s, c)
def url(name, u):
    case(name, side={**base_side, "channelUrl": u})
case("00-baseline")
case("01-sched-newline", settings={**base_settings, "schedule": {"mode": "window", "start": "03:00\n", "end": "05:00"}})
case("02-sched-arabic-digits", settings={**base_settings, "schedule": {"mode": "window", "start": "٠٣:٠٠", "end": "05:00"}})
case("03-sched-fullwidth-digits", settings={**base_settings, "schedule": {"mode": "window", "start": "０３:00", "end": "05:00"}})
url("10-url-dotdot", "https://updates.example.org/a/b/..")
url("11-url-dot", "https://updates.example.org/x/.")
url("12-url-port-big", "https://updates.example.org:99999")
url("13-url-port-alpha", "https://updates.example.org:abc")
url("14-url-space-host", "https://upd ates.example.org")
url("15-url-backslash-tail", "https://updates.example.org/a\\")
url("16-url-pct2e", "https://updates.example.org/%2e")
url("17-url-tab", "https://updates.exa\tmple.org")
url("18-url-lead-space", " https://updates.example.org")
url("19-url-trail-nl", "https://updates.example.org\n")
url("20-url-backslash-host", "https://updates.example.org\\path")
url("21-url-bad-punycode", "https://xn--a.org")
url("22-url-empty-query", "https://updates.example.org?")
url("23-url-empty-userinfo", "https://@updates.example.org")
url("24-url-root-slash", "https://updates.example.org/")
url("25-url-pct-host", "https://updates.ex%41mple.org")
url("26-url-ipv4-hex", "https://0x7f.1")
url("27-url-bad-ipv4", "https://1.2.3.256")
url("28-url-forbidden-host-char", "https://updates.example.org^x")
url("29-url-no-host-slashes", "https:updates.example.org")
url("30-url-triple-slash", "https:///updates.example.org")
url("31-url-upper-scheme", "HTTPS://updates.example.org")
url("32-url-dot-pct-tail", "https://updates.example.org/a/%2E")
url("33-url-percent-in-host-bad", "https://updates.example.org%2F")
url("34-url-pipe-host", "https://updates|example.org")
url("35-url-ipv6-zone", "https://[fe80::1%25eth0]")
url("36-url-c0-in-path", "https://updates.example.org/a\u0001")
case("40-schema-float", side={**base_side, "schema": 1.0})
case("41-bom", raw_side="﻿" + json.dumps(base_side))
case("42-settings-channelUrl", settings={**base_settings, "channelUrl": "https://updates.example.org"})
case("43-proto-key", raw_side=json.dumps(base_side)[:-1] + ', "__proto__": {}}')
case("44-escaped-dup", raw_side='{"schema":1,"channelUrl":"https://updates.example.org","channel":"stable","chann\\u0065l":"beta"}')
case("45-nan-schema", raw_side='{"schema":NaN,"channel":"stable","channelUrl":"https://updates.example.org"}')
case("46-big-ws", raw_side=json.dumps(base_side) + " " * 5000)
case("47-schema-1e0", raw_side='{"schema":1e0,"channel":"stable","channelUrl":"https://updates.example.org"}')
case("48-sched-empty", settings={**base_settings, "schedule": {}})
case("49-sched-window-only-start", settings={**base_settings, "schedule": {"mode": "window", "start": "23:59"}})
case("50-sched-null", settings={**base_settings, "schedule": None})
case("51-lone-surrogate-key", raw_settings='{"packagesAuto":false,"\\ud800":1}')
for name, (s, c) in cases.items():
    d = os.path.join(root, name); os.makedirs(d)
    open(os.path.join(d, "update-settings.json"), "w", encoding="utf-8").write(s)
    open(os.path.join(d, "update-image-channel.json"), "w", encoding="utf-8").write(c)
    print(name, "accept" if CERAUI[name] else "reject")
