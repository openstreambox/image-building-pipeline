#!/usr/bin/env bash
#
# licence-notices.test.sh — copyright files for first-party packages that ship
# without one, and MediaMTX's licence.
#
# Part A — install-licence-notices.sh against a fixture table, verbatim texts and
#          a dpkg-query stand-in: writes /usr/share/doc/<pkg>/copyright for
#          installed packages only, records a component without a licence file
#          without inventing text, and fails on a version mismatch, a changed or
#          missing text, a malformed row and a package that ships its own file.
# Part B — the committed table: versions match manifests/first-party-deb-versions.txt,
#          every vendored text matches its pin, and the real script produces the
#          three copyright files from it.
# Part C — setup_rtmp_gateway installs the verified tarball's LICENSE as
#          /usr/share/doc/mediamtx/copyright and refuses a tarball without one.
# Part D — the app layer runs the script after installing the first-party .debs
#          and before the doc prune, which keeps only files named copyright.
#
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
SCRIPT="${ROOT}/mkosi/runtime/licence-notices/install-licence-notices.sh"
TABLE="${ROOT}/mkosi/runtime/licence-notices/notices.tsv"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

# dpkg-query stand-in: answers from $WORK/<case>/installed ("pkg version" lines).
make_query() {
  local dir="$1"
  cat > "${dir}/dpkg-query" <<EOF
#!/usr/bin/env bash
pkg="\${!#}"
line="\$(grep -E "^\${pkg} " "${dir}/installed" || true)"
[[ -n "\${line}" ]] || exit 1
printf 'installed %s' "\${line#* }"
EOF
  chmod +x "${dir}/dpkg-query"
}

# A fixture case: table with one licensed package, one package holding a
# licensed component plus one without a licence file, and one absent package.
make_case() {
  local dir="${WORK}/$1"
  mkdir -p "${dir}/texts" "${dir}/root"
  printf 'Alpha licence text\nline two\n' > "${dir}/texts/alpha-LICENSE"
  printf 'Beta lib BSD text\n' > "${dir}/texts/beta-LICENSE.txt"
  local a b
  a="$(sha256sum "${dir}/texts/alpha-LICENSE" | awk '{print $1}')"
  b="$(sha256sum "${dir}/texts/beta-LICENSE.txt" | awk '{print $1}')"
  {
    printf '# comment\n\n'
    printf 'alpha\t1.0\talpha tool\thttps://example.invalid/alpha\t%s\tLICENSE\ttexts/alpha-LICENSE\t%s\n' "$(printf 'a%.0s' {1..40})" "${a}"
    printf 'beta\t2.0+x.1\tbundled lib\thttps://example.invalid/lib\t%s\tLICENSE.txt\ttexts/beta-LICENSE.txt\t%s\n' "$(printf 'b%.0s' {1..40})" "${b}"
    printf 'beta\t2.0+x.1\tthe plugin\thttps://example.invalid/plugin\t%s\t-\t-\t-\n' "$(printf 'c%.0s' {1..40})"
    printf 'gamma\t3.0\tgamma\thttps://example.invalid/gamma\t%s\tLICENSE\ttexts/alpha-LICENSE\t%s\n' "$(printf 'd%.0s' {1..40})" "${a}"
  } > "${dir}/notices.tsv"
  printf 'alpha 1.0\nbeta 2.0+x.1\n' > "${dir}/installed"
  make_query "${dir}"
}

run_case() { # <case> -> runs the script, output in $WORK/<case>/log
  local dir="${WORK}/$1"
  LICENCE_NOTICES_TABLE="${dir}/notices.tsv" LICENCE_NOTICES_DESTROOT="${dir}/root" \
    LICENCE_NOTICES_DPKG_QUERY="${dir}/dpkg-query" bash "${SCRIPT}" > "${dir}/log" 2>&1
}

expect_failure() { # <case> <message regex> <label>
  if run_case "$1"; then fail "$3: script succeeded"; fi
  grep -Eq "$2" "${WORK}/$1/log" || { cat "${WORK}/$1/log" >&2; fail "$3: wrong message"; }
  ok "$3"
}

# --- Part A -----------------------------------------------------------------
make_case good
run_case good || { cat "${WORK}/good/log" >&2; fail 'fixture table installs'; }
alpha="${WORK}/good/root/usr/share/doc/alpha/copyright"
beta="${WORK}/good/root/usr/share/doc/beta/copyright"
[[ -f "${alpha}" && -f "${beta}" ]] || fail 'copyright files written for installed packages'
[[ ! -e "${WORK}/good/root/usr/share/doc/gamma" ]] || fail 'absent package skipped'
grep -q 'gamma is not installed' "${WORK}/good/log" || fail 'skip is logged'
[[ "$(stat -c %a "${alpha}")" == 644 ]] || fail 'copyright mode 0644'
grep -Fxq 'alpha 1.0' "${alpha}" || fail 'header names package and version'
# The vendored text appears verbatim, byte for byte, at the end of the file.
[[ "$(tail -c "$(wc -c < "${WORK}/good/texts/alpha-LICENSE")" "${alpha}")" == "$(cat "${WORK}/good/texts/alpha-LICENSE")" ]] \
  || fail 'text copied verbatim'
grep -Fq "Source: https://example.invalid/lib at $(printf 'b%.0s' {1..40})" "${beta}" || fail 'source and commit recorded'
grep -Fq 'Beta lib BSD text' "${beta}" || fail 'licensed component text present'
grep -Fq 'Component: the plugin' "${beta}" || fail 'unlicensed component listed'
grep -Fq 'No licence file exists in this source at this commit' "${beta}" || fail 'unlicensed component stated as such'
grep -Fq 'The other texts in this file do not' "${beta}" || fail 'other texts are not stretched to cover it'
[[ "$(grep -c '^Component:' "${beta}")" == 2 ]] || fail 'both components of one package in one file'
ok 'writes verbatim copyright files for installed packages and records the unlicensed component'

make_case mismatch
printf 'alpha 1.1\nbeta 2.0+x.1\n' > "${WORK}/mismatch/installed"
expect_failure mismatch 'alpha 1\.1 is installed, but notices\.tsv pins 1\.0' 'fails when the installed version is not the pinned one'

make_case changed
printf 'edited\n' >> "${WORK}/changed/texts/beta-LICENSE.txt"
expect_failure changed 'pinned licence text changed: texts/beta-LICENSE\.txt' 'fails when a vendored text changed'

make_case missing
rm "${WORK}/missing/texts/alpha-LICENSE"
expect_failure missing 'pinned licence text missing' 'fails when a vendored text is missing'

make_case owned
mkdir -p "${WORK}/owned/root/usr/share/doc/alpha"
printf 'package-provided\n' > "${WORK}/owned/root/usr/share/doc/alpha/copyright"
expect_failure owned 'alpha now ships its own /usr/share/doc/alpha' 'fails when the package ships its own copyright file'
grep -Fxq 'package-provided' "${WORK}/owned/root/usr/share/doc/alpha/copyright" || fail 'package-provided file left untouched'

make_case malformed
printf 'delta\t1.0\tdelta\thttps://example.invalid/d\tnot-a-sha\tLICENSE\ttexts/alpha-LICENSE\tx\n' >> "${WORK}/malformed/notices.tsv"
expect_failure malformed "malformed row for 'delta'" 'fails on a malformed row'

make_case mixed
printf 'beta\t2.0+x.1\tmixed\thttps://example.invalid/m\t%s\tLICENSE\t-\t-\n' "$(printf 'e%.0s' {1..40})" >> "${WORK}/mixed/notices.tsv"
expect_failure mixed "mixes '-' with a text" 'fails on a half-empty row'

# --- Part B -----------------------------------------------------------------
pins="${ROOT}/manifests/first-party-deb-versions.txt"
mkdir -p "${WORK}/real/root"
: > "${WORK}/real/installed"
while IFS=$'\t' read -r pkg ver _ _ commit _ text sha _; do
  [[ -z "${pkg}" || "${pkg}" == \#* ]] && continue
  grep -Fxq "${pkg}=${ver}" "${pins}" || fail "notices.tsv pins ${pkg} ${ver}, first-party-deb-versions.txt does not"
  [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || fail "${pkg}: commit is not a full SHA"
  if [[ "${text}" != "-" ]]; then
    [[ "$(sha256sum "$(dirname "${TABLE}")/${text}" | awk '{print $1}')" == "${sha}" ]] || fail "${text} does not match its pin"
  fi
  grep -q "^${pkg} " "${WORK}/real/installed" || printf '%s %s\n' "${pkg}" "${ver}" >> "${WORK}/real/installed"
done < "${TABLE}"
make_query "${WORK}/real"
LICENCE_NOTICES_DESTROOT="${WORK}/real/root" LICENCE_NOTICES_DPKG_QUERY="${WORK}/real/dpkg-query" \
  bash "${SCRIPT}" > "${WORK}/real/log" 2>&1 || { cat "${WORK}/real/log" >&2; fail 'committed table installs'; }
for pkg in srtla libsrt1.5-ceralive gstreamer1.0-libuvcsrc; do
  [[ -s "${WORK}/real/root/usr/share/doc/${pkg}/copyright" ]] || fail "committed table writes ${pkg}"
done
grep -Fq 'Mozilla Public License Version 2.0' "${WORK}/real/root/usr/share/doc/libsrt1.5-ceralive/copyright" || fail 'libsrt text'
grep -Fq 'MIT License' "${WORK}/real/root/usr/share/doc/srtla/copyright" || fail 'srtla text'
uvc="${WORK}/real/root/usr/share/doc/gstreamer1.0-libuvcsrc/copyright"
grep -Fq 'Software License Agreement (BSD License)' "${uvc}" || fail 'libuvc text'
grep -Fq 'Source: https://github.com/CERALIVE/gstlibuvcsrc at 8fe5ba50e8c28ceeffba8a3b896b245fff53bd96' "${uvc}" \
  || fail 'plugin source recorded'
grep -Fq 'No licence file exists in this source at this commit' "${uvc}" || fail 'plugin recorded without a licence text'
ok 'committed table matches the deb pins and its texts, and writes srtla, libsrt and libuvcsrc copyright files'

# --- Part C -----------------------------------------------------------------
# Real setup_rtmp_gateway from the module set, against a tiny local tarball.
mtx="${WORK}/mediamtx"
mkdir -p "${mtx}/payload" "${mtx}/nolicence" "${mtx}/dest"
printf '#!/bin/sh\n' > "${mtx}/payload/mediamtx"
printf 'paths: {}\n' > "${mtx}/payload/mediamtx.yml"
printf 'MIT License\n\nCopyright (c) fixture\n' > "${mtx}/payload/LICENSE"
tar -czf "${mtx}/with.tar.gz" -C "${mtx}/payload" mediamtx mediamtx.yml LICENSE
cp "${mtx}/payload/mediamtx" "${mtx}/payload/mediamtx.yml" "${mtx}/nolicence/"
tar -czf "${mtx}/without.tar.gz" -C "${mtx}/nolicence" mediamtx mediamtx.yml

gateway() { # <tarball> <destroot>
  local tarball="$1"
  {
    printf 'MEDIAMTX_VERSION=v0.0.0\n'
    printf 'MEDIAMTX_URL_TEMPLATE=https://example.invalid/{ver}/{arch}.tar.gz\n'
    printf 'MEDIAMTX_SHA256_arm64=%s\n' "$(sha256sum "${tarball}" | awk '{print $1}')"
  } > "${mtx}/recipe.conf"
  (
    export CERALIVE_RUNTIME_SRC="${ROOT}/mkosi/runtime"
    # shellcheck source=../mkosi/customize/postinst-lib.sh
    source "${ROOT}/mkosi/customize/postinst-lib.sh"
    enable_service() { :; }
    MEDIAMTX_RECIPE="${mtx}/recipe.conf" MEDIAMTX_ARCH=arm64 MEDIAMTX_LOCAL_TARBALL="${tarball}" \
      MEDIAMTX_DESTROOT="$2" setup_rtmp_gateway
  )
}

gateway "${mtx}/with.tar.gz" "${mtx}/dest" > "${mtx}/log" 2>&1 || { cat "${mtx}/log" >&2; fail 'gateway installs'; }
copyright="${mtx}/dest/usr/share/doc/mediamtx/copyright"
[[ -f "${copyright}" && "$(stat -c %a "${copyright}")" == 644 ]] || fail 'MediaMTX copyright installed 0644'
grep -Fq 'Copyright (c) fixture' "${copyright}" || fail 'MediaMTX licence copied from the tarball'
grep -Fq "Release tarball sha256: $(sha256sum "${mtx}/with.tar.gz" | awk '{print $1}')" "${copyright}" \
  || fail 'MediaMTX tarball hash recorded'
[[ -x "${mtx}/dest/usr/local/bin/mediamtx" ]] || fail 'MediaMTX binary still installed'
ok 'setup_rtmp_gateway installs the tarball LICENSE as /usr/share/doc/mediamtx/copyright'

if gateway "${mtx}/without.tar.gz" "${mtx}/dest2" > "${mtx}/log2" 2>&1; then
  fail 'a MediaMTX tarball without LICENSE was accepted'
fi
grep -q 'MediaMTX tarball missing its LICENSE member' "${mtx}/log2" || { cat "${mtx}/log2" >&2; fail 'missing LICENSE message'; }
[[ ! -e "${mtx}/dest2/usr/local/bin/mediamtx" ]] || fail 'nothing installed from a tarball without LICENSE'
ok 'setup_rtmp_gateway refuses a tarball without LICENSE'

grep -Fq '(MIT)' "${ROOT}/mkosi/runtime/rtmp-gateway/mediamtx.recipe.conf" || fail 'recipe names MediaMTX licence correctly'

# --- Part D -----------------------------------------------------------------
app="${ROOT}/mkosi/mkosi.images/app/mkosi.postinst.chroot"
notices_line="$(grep -n 'runtime/licence-notices/install-licence-notices.sh' "${app}" | head -1 | cut -d: -f1)"
install_line="$(grep -n '^    install_first_party_apps$' "${app}" | head -1 | cut -d: -f1)"
prune_line="$(grep -n '^  prune_final_image_payload$' "${app}" | head -1 | cut -d: -f1)"
[[ -n "${notices_line}" && -n "${install_line}" && -n "${prune_line}" ]] || fail 'app layer wiring found'
(( install_line < notices_line && notices_line < prune_line )) || fail 'notices run after install and before the prune'
[[ -x "${SCRIPT}" ]] || fail 'notice script executable'
ok 'app layer writes notices after installing first-party packages and before the doc prune'

printf 'PASS: licence notices (%d checks)\n' "${pass}"
