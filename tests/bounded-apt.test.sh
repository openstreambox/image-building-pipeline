#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source mkosi/customize/postinst.d/persistence.sh
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
install_bounded_apt_metadata "$w"
install_bounded_apt_metadata "$w"
[[ $(grep -Fxc 'tmpfs /var/lib/apt/lists tmpfs nosuid,nodev,noexec,size=192M,mode=0755 0 0' "$w/etc/fstab") -eq 1 ]]
grep -Fxq 'tmpfs /var/lib/apt/lists tmpfs nosuid,nodev,noexec,size=192M,mode=0755 0 0' "$w/etc/fstab"
apt-config -c "$w/etc/apt/apt.conf.d/82bounded-metadata" dump >"$w/config"
grep -Fxq 'Dir::Cache::pkgcache "";' "$w/config"
grep -Fxq 'Dir::Cache::srcpkgcache "";' "$w/config"
# No transaction hooks remove the lists that an install following update needs.
! grep -q 'Post-Invoke' "$w/etc/apt/apt.conf.d/82bounded-metadata"
# Board-specific setup must follow the shared attention installation so every
# board receives diagnostics before customization enters its optional path.
python3 - <<'PY'
from pathlib import Path
s = Path('mkosi/customize/postinst.d/persistence.sh').read_text()
body = s[s.index('setup_data_persistence() {'):]
assert body.index('ceralive-attention.py') < body.index('install_bounded_apt_metadata /')
assert body.count('install_bounded_apt_metadata /') == 1
PY
