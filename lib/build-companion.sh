#!/usr/bin/env bash
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PIPELINE_DIR"
# shellcheck source=lib/fetch-debs.sh
source lib/fetch-debs.sh
# shellcheck source=lib/shared/target-release-lib.sh
source lib/shared/target-release-lib.sh
# shellcheck source=lib/shared/apt-proxy-lib.sh
source lib/shared/apt-proxy-lib.sh
# shellcheck source=lib/kernel/builder.sh
source lib/kernel/builder.sh
# shellcheck source=lib/stages/mkosi.sh
source lib/stages/mkosi.sh

board="$1"
[[ "$(realpath "$2")" == "$PIPELINE_DIR/manifests/boards/$board.yaml" ]] || die "unexpected board manifest"
resolved="$(lib/resolve.sh "$board" --variant default)"
eval "$resolved"
[[ "${FAMILY}" == rk3566 && "${BOARD_ID}" == radxa-zero3 ]] || die "unexpected companion board"
[[ "${CERALIVE_BUILD_MODE:-development}" != production ]] || die "companion is a local image"
target_release_load

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  printf 'Companion image: %s %s, %s, USB NCM+ACM, Debian %s\n' \
    "$board" "$COMPANION_KERNEL_TAG" "$DTB_NAME" "$RELEASE"
  exit 0
fi

key="${CERALIVE_COMPANION_SSH_KEY:-}"
[[ -f "$key" ]] || die "set CERALIVE_COMPANION_SSH_KEY to the bench OpenSSH public key file"
[[ "$(wc -l < "$key")" == 1 ]] && grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+( |$)' "$key" \
  && ssh-keygen -l -f "$key" >/dev/null || die "expected one Ed25519 public key"
require_cmd fdtget
require_cmd docker
sudo -n true

mkdir -p mkosi/build "images/$board"
work="$(mktemp -d "$PIPELINE_DIR/mkosi/build/zero3w.XXXXXX")"
mkdir -p "$work"/{bsp,modules,output}
export UBOOT_PACKAGES
DRY_RUN=
DEST="$work"
fetch_bsp "$PIPELINE_DIR/manifests/families/$FAMILY.yaml" "$work/bsp"

MKOSI_VERSION_PIN="$(cat .mkosi-version)"
MKOSI_BUILDER_DOCKERFILE="$PIPELINE_DIR/ci/Dockerfile"
MKOSI_BUILDER_IMAGE_OVERRIDDEN=0
MKOSI_BUILDER_IMAGE="ceralive-mkosi-builder:${MKOSI_VERSION_PIN}-$(sha256sum ci/Dockerfile | cut -c1-12)"
ensure_builder_image docker
docker run --rm --privileged -v "$work:/work" -v "$PIPELINE_DIR/mkosi/companion:/config:ro" \
  "$MKOSI_BUILDER_IMAGE" mkosi --directory=/config --release="$RELEASE" \
  --output-directory=/work --workspace-directory=/work --with-network=yes build

KERNEL_BUILDER_DOCKERFILE="$PIPELINE_DIR/ci/Dockerfile.kernel"
kernel_builder="$(resolve_kernel_builder_tag "$COMPANION_KERNEL_BUILDER_IMAGE")"
ensure_kernel_builder_image docker "$COMPANION_KERNEL_BUILDER_IMAGE" "$kernel_builder"
jobs="$(derive_kernel_build_jobs)"
kernel_mirror=()
if [[ -n "${CERALIVE_KERNEL_SRC_MIRROR_DIR:-}" ]]; then
  [[ -d "$CERALIVE_KERNEL_SRC_MIRROR_DIR" ]] || die "kernel source mirror directory does not exist"
  kernel_mirror=(-v "$(realpath "$CERALIVE_KERNEL_SRC_MIRROR_DIR"):/kernel-mirror:ro")
fi
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e CCACHE_DISABLE=1 \
  -e CERALIVE_KERNEL_GIT_TIMEOUT -e CERALIVE_KERNEL_GIT_ATTEMPTS \
  -v "$PIPELINE_DIR:/pipeline:ro" -v "$work:/work" "${kernel_mirror[@]}" -w /work \
  "$kernel_builder" bash /pipeline/lib/companion-kernel.sh \
  "$COMPANION_KERNEL_TAG" "$COMPANION_KERNEL_COMMIT" "$COMPANION_KERNEL_FRAGMENT" "$DTB_NAME" "$jobs"

rootfs="$work/rootfs"
sudo -n bash lib/companion-rootfs.sh "$rootfs" "$work" "$DTB_NAME" "$key"
sudo -n bash lib/measure-size.sh "$board" "$rootfs"
raw="$work/output/radxa-zero-3w-companion.raw"
sudo -n env DTB_NAME="$DTB_NAME" SERIAL_CONSOLE="$SERIAL_CONSOLE" \
  COMPATIBLE_STRING="ceralive-$BOARD_ID" \
  lib/assemble-disk.sh build --output "$raw" --rootfs-tree "$rootfs" \
  --board "$BOARD_ID" --bootloader-adapter custom --bsp-dir "$work/bsp"
sudo -n chown "$(id -u):$(id -g)" "$raw"
bash lib/verify-companion.sh "$raw" "$work" "$DTB_NAME"
bash ci/seal-raw-candidate.sh --raw "$raw" --candidate-dir "$work/output" --raw-sha256 "$raw.sha256"
mv "$work/output" "images/$board/${work##*/}"
