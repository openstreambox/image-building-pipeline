#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source mkosi/customize/postinst.d/persistence.sh
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
install_bounded_apt_metadata "$w"
grep -Fxq 'tmpfs /var/lib/apt/lists tmpfs nosuid,nodev,noexec,size=192M,mode=0755 0 0' "$w/etc/fstab"
apt-config -c "$w/etc/apt/apt.conf.d/82bounded-metadata" dump >"$w/config"
grep -Fxq 'Dir::Cache::pkgcache "";' "$w/config"
grep -Fxq 'Dir::Cache::srcpkgcache "";' "$w/config"
# No transaction hooks remove the lists that an install following update needs.
! grep -q 'Post-Invoke' "$w/etc/apt/apt.conf.d/82bounded-metadata"
