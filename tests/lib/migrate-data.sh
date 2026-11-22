# shellcheck shell=bash
# Render the shipped migrate-data body with its system paths inside the fixture.
# Two slot directories can share one data directory. A runner can impose I/O limits.
migrate() {
  local d="$1" data="${2:-$1/data}" runner="${3:-bash}"
  mkdir -p "$d/bin" "$d/etc/ceralive" "$data" "$d/varlog" "$d/nm"
  printf '#!/bin/sh\nexit 1\n' >"$d/bin/mountpoint"
  printf '#!/bin/sh\nexit 0\n' >"$d/bin/logger"
  chmod +x "$d/bin/mountpoint" "$d/bin/logger"
  {
    echo 'set -euo pipefail'
    printf 'DATA=%q\nWORKDIR=%q\nNM_CONN=%q\nCERAUI_HELPERS=%q\n' \
      "$data" "$d/opt/ceralive" "$d/nm" "$d/ceraui-workdir"
    awk '/cat >>\/usr\/local\/sbin\/ceralive-migrate-data <<.EOF./{on=1; next} on && /^EOF$/{exit} on' \
      "$PIPELINE_DIR/mkosi/customize/postinst.d/persistence.sh" |
      sed -e "s#/etc/ceralive#$d/etc/ceralive#g" -e "s#/var/log#$d/varlog#g" \
        -e "s#/usr/local/sbin/tailscaled#$d/tailscaled#g" -e "s#/usr/libexec/ceralive/ceraui-stamps#$d/stamps#g"
  } >"$d/migrate.sh"
  grep -q 'update preset pair' "$d/migrate.sh"
  PATH="$d/bin:$PATH" "$runner" "$d/migrate.sh" >"$d/migrate.log" 2>&1
}
