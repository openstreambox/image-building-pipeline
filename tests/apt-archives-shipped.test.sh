#!/usr/bin/env bash
#
# apt-archives-shipped.test.sh — the finished rootfs ships no downloaded apt
# packages, from either archive directory a build can download into.
#
# WHY: the runtime layer downloads shared.list into apt's default
# /var/cache/apt/archives and only then writes 81ceralive-cache, which points the
# DEVICE's apt at /data/ceralive/apt-archives/. The app layer inherits that
# redirect, so its bare `apt-get clean` emptied the /data path and left every
# downloaded package (412 of them, 206 MB, in one measured image) in the slot.
#
# Part A — static contract: the cause still exists, the app layer cleans through
#          clean_apt_archives and ends with assert_no_apt_archives, and the tar
#          guard watches the same /data path 81ceralive-cache configures.
# Part B — the REAL clean_apt_archives / assert_no_apt_archives with real apt-get
#          under the same redirect: both directories emptied, packages of every
#          version, architecture and partial shape removed, a payload .deb
#          elsewhere and the device cache setting untouched, fail closed on a
#          leftover, refusal of a symlinked archive directory.
# Part C — the REAL stage_tar_emit and verify-no-apt-archives.sh on emitted tars.
#
# Offline and rootless: scratch apt state and directories, no chroot, no host apt.
# Profile: contract-test (docs/shell-profiles.md).
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
APP_POSTINST="${REPO}/mkosi/mkosi.images/app/mkosi.postinst.chroot"
RUNTIME_POSTINST="${REPO}/mkosi/mkosi.images/runtime/mkosi.postinst.chroot"
VERIFY="${REPO}/lib/verify-no-apt-archives.sh"
# shellcheck source=tests/lib/assertions.sh
source "${HERE}/lib/assertions.sh"

WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/apt-archives-shipped.XXXXXX")"
finish() {
  rm -rf "${WORK}"
  printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
  [[ "${FAIL}" -eq 0 ]]
}
trap 'finish; exit $?' EXIT

# --- Part A: static contract -------------------------------------------------
# (An earlier main() sits inside a heredoc of the runtime executor; take the last.)
runtime_main="$(awk '/^main\(\) \{/{buf=""} {buf=buf $0 "\n"} /^main\(\) \{/{f=1} f && /^\}/{out=buf; f=0} END{printf "%s", out}' "${RUNTIME_POSTINST}")"
install_line="$(grep -n '^  install_runtime_packages' <<<"${runtime_main}" | cut -d: -f1)"
redirect_line="$(grep -n '^  setup_prune_reprune_and_cache' <<<"${runtime_main}" | cut -d: -f1)"
[[ -n "${install_line}" && -n "${redirect_line}" && "${install_line}" -lt "${redirect_line}" ]] \
  && ok 'the runtime layer downloads packages before it redirects the device cache' \
  || bad 'runtime main() order changed; re-check which directories hold downloaded packages'
device_cache="$(sed -n 's/^Dir::Cache::archives "\(.*\)";$/\1/p' "${RUNTIME_POSTINST}")"
assert_eq 'the device apt cache is redirected to /data (inherited by the app layer)' \
  '/data/ceralive/apt-archives/' "${device_cache}"
device_rel="${device_cache#/}"
grep -Fq "APT_ARCHIVE_DIRS=(var/cache/apt/archives ${device_rel%/})" "${VERIFY}" \
  && ok 'the tar guard watches the default and the configured device archive directory' \
  || bad "verify-no-apt-archives.sh does not watch ${device_cache}"

app_clean="$(awk '/^clean_package_download_metadata\(\) \{/{f=1} f{print} f && /^\}/{exit}' "${APP_POSTINST}")"
grep -Eq '^[[:space:]]*clean_apt_archives[[:space:]]*$' <<<"${app_clean}" \
  && ok 'clean_package_download_metadata() empties the archives through clean_apt_archives' \
  || bad 'clean_package_download_metadata() no longer calls clean_apt_archives'
if grep -Eq '^[[:space:]]*apt-get[[:space:]]+clean' "${APP_POSTINST}"; then
  bad 'a bare "apt-get clean" follows the /data redirect and leaves the shipped packages'
else
  ok 'no bare "apt-get clean" in the app layer'
fi
app_main="$(awk '/^main\(\) \{/{f=1} f{print} f && /^\}/{exit}' "${APP_POSTINST}")"
last_call="$(grep -Ev '^[[:space:]]*(#|$|log |\})' <<<"${app_main}" | tail -n 1 | tr -d '[:space:]')"
assert_eq 'the app layer ends with assert_no_apt_archives' 'assert_no_apt_archives' "${last_call}"
grep -Fq '"${VERIFY_NO_APT_ARCHIVES_SH}" "${artifact}"' "${REPO}/lib/stages/tar-emit.sh" \
  && ok 'stage_tar_emit checks the emitted tar' || bad 'stage_tar_emit no longer runs the tar guard'

# --- Part B: behaviour -------------------------------------------------------
if ! command -v apt-get >/dev/null 2>&1 || ! command -v apt-config >/dev/null 2>&1; then
  echo 'apt-archives-shipped: apt-get/apt-config unavailable, behaviour leg skipped'
else
  root="${WORK}/root"
  shipped="${root}/var/cache/apt/archives"
  device="${root}/data/ceralive/apt-archives"
  payload="${root}/opt/payload/keep_1.0_arm64.deb"
  mkdir -p "${WORK}/state/lists/partial" "${WORK}/etc"
  : >"${WORK}/status"
  # The same redirect 81ceralive-cache installs, plus scratch state so apt never
  # touches the host's /var/lib/apt or /var/cache/apt.
  cat >"${WORK}/etc/apt.conf" <<CONF
Dir::State "${WORK}/state/";
Dir::State::status "${WORK}/status";
Dir::Cache "${WORK}/cache/";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
Dir::Cache::archives "${device}/";
CONF
  cp "${WORK}/etc/apt.conf" "${WORK}/apt.conf.before"
  fill() {
    rm -rf "${shipped}" "${device}" "$(dirname "${payload}")"
    mkdir -p "${shipped}/partial" "${device}/partial" "$(dirname "${payload}")"
    local d
    for d in "${shipped}" "${device}"; do
      printf 'deb\n' >"${d}/libfoo1_1.2-3_arm64.deb"
      printf 'deb\n' >"${d}/tzdata_2026a-1_all.deb"
      printf 'deb\n' >"${d}/modemmanager_1%3a1.24.0-1+b1_arm64.deb"
      printf 'deb\n' >"${d}/libsrt1.5-gnutls_1.5.4-1_arm64.deb"
      printf 'part\n' >"${d}/partial/libbar2_2.0~rc1-1_arm64.deb"
      printf 'udeb\n' >"${d}/installer-bit_1.0_arm64.udeb"
      : >"${d}/lock"
    done
    printf 'payload\n' >"${payload}"
  }
  count_pkgs() { find "$1" \( -name '*.deb' -o -name '*.udeb' -o -path '*/partial/*' \) | wc -l; }
  run_app() { # <function> [args...] — the real app-layer functions, sourced (main stays unrun)
    ( # shellcheck source=mkosi/mkosi.images/app/mkosi.postinst.chroot
      source "${APP_POSTINST}"
      export APT_CONFIG="${WORK}/etc/apt.conf" SHIPPED_APT_ARCHIVES="${shipped}"
      "$@"
    )
  }

  # Control: the bare command the app layer used to run keeps the shipped packages.
  fill
  APT_CONFIG="${WORK}/etc/apt.conf" apt-get clean >/dev/null 2>&1
  assert_eq 'bare apt-get clean under the /data redirect leaves the shipped packages (control)' \
    6 "$(count_pkgs "${shipped}")"

  fill
  if run_app clean_apt_archives >"${WORK}/clean.log" 2>&1; then
    ok 'clean_apt_archives succeeds'
  else
    bad "clean_apt_archives failed: $(cat "${WORK}/clean.log")"
  fi
  assert_eq 'no package remains in the default archive directory' 0 "$(count_pkgs "${shipped}")"
  assert_eq 'no package remains in the redirected device archive directory' 0 "$(count_pkgs "${device}")"
  [[ -d "${shipped}/partial" && -d "${device}/partial" ]] && ok 'partial/ directories are kept' \
    || bad 'a partial/ directory was removed'
  [[ -f "${payload}" ]] && ok 'a .deb outside the archive directories is untouched' \
    || bad 'clean_apt_archives removed a payload .deb outside the archive directories'
  cmp -s "${WORK}/etc/apt.conf" "${WORK}/apt.conf.before" \
    && ok 'the device cache configuration is unchanged' || bad 'the apt configuration was modified'
  grep -Fq "emptying apt archive directory ${device}" "${WORK}/clean.log" \
    && ok 'the configured Dir::Cache::archives is resolved through apt-config' \
    || bad 'the redirected directory was not cleaned by name'

  # The final guard: a leftover of any shape in either directory fails the build;
  # a payload .deb elsewhere does not.
  for leftover in "${shipped}/late_1.0_arm64.deb" "${device}/late_2%3a1.0_all.deb" \
                  "${shipped}/partial/late_1.0_arm64.deb" "${device}/late.deb.FAILED"; do
    fill; run_app clean_apt_archives >/dev/null 2>&1
    printf 'late\n' >"${leftover}"
    if run_app assert_no_apt_archives >"${WORK}/assert.log" 2>&1; then
      bad "assert_no_apt_archives accepted ${leftover#"${root}"}"
    else
      grep -q 'downloaded packages remain' "${WORK}/assert.log" \
        && ok "assert_no_apt_archives fails on ${leftover#"${root}"}" \
        || bad "unexpected failure: $(cat "${WORK}/assert.log")"
    fi
  done
  fill; run_app clean_apt_archives >/dev/null 2>&1
  run_app assert_no_apt_archives >/dev/null 2>&1 \
    && ok 'assert_no_apt_archives passes with only a payload .deb elsewhere' \
    || bad 'assert_no_apt_archives rejected a payload .deb outside the archive directories'

  # Fail closed: a clean that removes nothing must stop the build.
  fill
  clean_that_removes_nothing() { apt-get() { :; }; clean_apt_archives; }
  if run_app clean_that_removes_nothing >"${WORK}/noop.log" 2>&1; then
    bad 'a package left behind by the clean did not fail the build'
  else
    grep -q 'downloaded packages remain' "${WORK}/noop.log" \
      && ok 'a package left behind by the clean fails the build' || bad "unexpected: $(cat "${WORK}/noop.log")"
  fi

  # Never clean through a symlink: its target is not an archive directory.
  fill
  mkdir -p "${WORK}/elsewhere"
  printf 'not ours\n' >"${WORK}/elsewhere/precious_1.0_all.deb"
  rm -rf "${device}"; ln -s "${WORK}/elsewhere" "${device}"
  if run_app clean_apt_archives >"${WORK}/link.log" 2>&1; then
    bad 'clean_apt_archives cleaned through a symlinked archive directory'
  else
    grep -q 'is a symlink; refusing' "${WORK}/link.log" \
      && ok 'a symlinked archive directory is refused' || bad "unexpected: $(cat "${WORK}/link.log")"
  fi
  [[ -f "${WORK}/elsewhere/precious_1.0_all.deb" ]] && ok 'the symlink target is untouched' \
    || bad 'a file behind the symlink was deleted'
  rm -f "${device}"
fi

# --- Part C: the emitted tar --------------------------------------------------
tree="${WORK}/tree"
mkdir -p "${tree}/var/cache/apt/archives/partial" "${tree}/data" "${tree}/opt/payload" "${tree}/usr/bin"
: >"${tree}/var/cache/apt/archives/lock"
printf 'payload\n' >"${tree}/opt/payload/keep_1.0_arm64.deb"
printf '#!/bin/sh\n' >"${tree}/usr/bin/tool"
emit() { # <out dir> — the REAL stage_tar_emit, as orchestrate.sh runs it
  ( set -euo pipefail
    log_info() { :; }; log_success() { :; }
    die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
    # shellcheck source=lib/stages/tar-emit.sh
    source "${REPO}/lib/stages/tar-emit.sh"
    IMAGES_DIR="$1" board=fixture ts=t1 rootfs_tree="${tree}" SOURCE_DATE_EPOCH=0
    VERIFY_NO_APT_ARCHIVES_SH="${VERIFY}"
    stage_tar_emit
  )
}
emit "${WORK}/img-clean" >"${WORK}/emit.log" 2>&1 \
  && ok 'stage_tar_emit accepts a tree without downloaded packages (payload .deb elsewhere)' \
  || bad "stage_tar_emit failed on a clean tree: $(cat "${WORK}/emit.log")"
for member in var/cache/apt/archives/libfoo1_1.2-3_arm64.deb \
              var/cache/apt/archives/partial/libbar2_2.0~rc1-1_arm64.deb \
              data/ceralive/apt-archives/modemmanager_1%3a1.24.0-1_all.deb \
              var/cache/apt/archives/x_1.0_arm64.udeb; do
  mkdir -p "$(dirname "${tree}/${member}")"
  printf 'deb\n' >"${tree}/${member}"
  if emit "${WORK}/img-dirty" >"${WORK}/emit.log" 2>&1; then
    bad "stage_tar_emit shipped ${member}"
  else
    grep -q 'downloaded apt packages' "${WORK}/emit.log" && grep -Fq "${member}" "${WORK}/emit.log" \
      && ok "stage_tar_emit refuses a tar shipping ${member}" || bad "unexpected: $(cat "${WORK}/emit.log")"
  fi
  rm -f "${tree}/${member}"
done
"${VERIFY}" "${WORK}/missing.tar" >/dev/null 2>&1 && bad 'a missing tar was accepted' \
  || ok 'a missing tar fails the guard'

[[ "${FAIL}" -eq 0 ]]
