#!/usr/bin/env bash
# Native CI prerequisites in the disposable VM. Never run on the workstation.
#
# Usage: ci/kernel-runner/ci-tests.sh [--privileged-only]
#   (default)          full ./run-tests with every real contract required
#   --privileged-only  only the registry's `privileged` rows, each run to the end
#                      so one failure does not hide the others
set -euo pipefail
case "${1:-}" in
  '') only_privileged=0 ;;
  --privileged-only) only_privileged=1 ;;
  *) printf 'usage: %s [--privileged-only]\n' "$0" >&2; exit 2 ;;
esac
# shellcheck source=tests/lib/require-disposable-guest.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/tests/lib/require-disposable-guest.sh"
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${ROOT}"
python3 -m venv "${RUNNER_TEMP}/python"
export PATH="${RUNNER_TEMP}/python/bin:${PATH}"
pip install --quiet --requirement ci/requirements-ci.txt
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
pin() { awk -F= -v key="$1" '$1 == key {print $2; exit}' manifests/rauc-deb-versions.txt; }
version="$(pin UPSTREAM_VERSION)"
curl -fsSL --connect-timeout 30 --max-time 300 "$(pin UPSTREAM_URL)" -o "${work}/rauc.tar.xz"
printf '%s  %s\n' "$(pin UPSTREAM_SHA256)" "${work}/rauc.tar.xz" | sha256sum -c -
mkdir "${work}/source"
tar -xf "${work}/rauc.tar.xz" -C "${work}/source" --strip-components=1
meson setup "${work}/build" "${work}/source" --prefix=/usr/local \
  -Dtests=false -Dgpt=enabled -Dstreaming=true -Djson=enabled \
  -Dsystemdunitdir=/usr/lib/systemd/system \
  -Ddbussystemservicedir=/usr/share/dbus-1/system-services \
  -Ddbuspolicydir=/usr/share/dbus-1/system.d
meson compile -C "${work}/build"
sudo meson install -C "${work}/build"
[[ "$(rauc --version)" == "rauc ${version}" ]]
getent passwd ceralive-ota >/dev/null || sudo useradd --system --no-create-home --shell /usr/sbin/nologin ceralive-ota
sudo busctl call --system org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig
source manifests/target-release.env
docker pull "debian:${RELEASE}"
docker pull "debian:${RELEASE}-slim"
container="$(docker create --network none "debian:${RELEASE}")"
trap 'docker rm "${container}"; rm -rf -- "${work}"' EXIT
docker export "${container}" >"${RUNNER_TEMP}/kernel-stage-rootfs.tar"
export CERALIVE_KERNEL_STAGE_ROOTFS="${RUNNER_TEMP}/kernel-stage-rootfs.tar"
export CERALIVE_RUN_REAL_AVAHI_CONTRACT=required \
  CERALIVE_RUN_REAL_RAUC_CONTRACT=disposable-marked-guest-only \
  CERALIVE_RUN_REAL_KERNEL_STAGE_CONTRACT=required \
  CERALIVE_RUN_REAL_PRIVILEGE_DROP_CONTRACT=required
if (( ! only_privileged )); then
  ./run-tests
  exit
fi
mapfile -t rows < <(awk -F'\t' '!/^[[:space:]]*(#|$)/ && NF >= 4 && $3 == "privileged" { print $1 }' tests/registry.tsv)
(( ${#rows[@]} > 0 )) || { printf 'registry declares no privileged rows\n' >&2; exit 1; }
failed=0
for row in "${rows[@]}"; do
  printf '== privileged row: %s ==\n' "${row}"
  started="${SECONDS}"
  rc=0
  bash "${row}" || rc=$?
  printf 'CERALIVE_PRIVILEGED_ROW rc=%s seconds=%s %s\n' "${rc}" "$((SECONDS - started))" "${row}"
  (( rc == 0 )) || failed=1
done
exit "${failed}"
