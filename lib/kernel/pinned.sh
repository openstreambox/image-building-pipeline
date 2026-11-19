#!/usr/bin/env bash
# kernel/pinned.sh — reuse a SHA-pinned kernel artifact instead of compiling.
#
# Sourced by lib/kernel/released.sh, never executed. Like released.sh it sits
# OUTSIDE the producer fingerprint: it decides whether the producer runs, and it
# never changes what the producer builds.
#
# A pin (manifests/kernel/pins/<package_version>.json) names the exact bytes of
# one built kernel (deb, resolved.config, built-modules.txt), the source inputs
# that produced them and the producer's own kernel-artifact.json record. When the
# manifest's kernel inputs equal the pin's, the stage takes those bytes from a
# trusted store instead of compiling them again:
#   1. the kernel artifact cache (CERALIVE_KERNEL_CACHE_DIR or the in-tree one;
#      skipped when CERALIVE_KERNEL_ARTIFACT_CACHE=0),
#      looked up by content, so a producer-code change that moved the cache key
#      does not hide a byte-identical kernel;
#   2. the pin's "sources": HTTPS base URLs (a published release asset).
# Every candidate is checked against the pinned sha256 values and then through
# the same deb and Kconfig gates a fresh build passes.
#
# CERALIVE_KERNEL_PIN
#   auto     (default) use the pinned artifact; if no store has it, compile and
#            require the result to equal the pin.
#   require  release builds: use the pinned artifact or stop. Never compiles.
#   verify   the scheduled "can we still build it" check: always compile (pair
#            it with CERALIVE_KERNEL_ARTIFACT_CACHE=0 and an empty
#            CERALIVE_KERNEL_CACHE_DIR), then require the result to equal the pin.
#   0        ignore pins.
# A pin whose source inputs differ from the manifest stops the build in every
# mode but 0: the manifest asks for a different kernel than the one pinned.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

KERNEL_PIN_FORMAT='ceralive-kernel-pin/1'

kernel_pin_mode() {
  case "${CERALIVE_KERNEL_PIN:-auto}" in
    auto|require|verify|0) printf '%s' "${CERALIVE_KERNEL_PIN:-auto}" ;;
    *) die "CERALIVE_KERNEL_PIN must be auto, require, verify or 0 (got '${CERALIVE_KERNEL_PIN}')"; return 1 ;;
  esac
}

kernel_pin_file() {
  printf '%s/%s.json' "${CERALIVE_KERNEL_PIN_DIR:-${PIPELINE_DIR}/manifests/kernel/pins}" "${package_version}"
}

# The kernel's source inputs from the resolved manifest, as canonical JSON. Every
# value the container build consumes from the manifest is here; fragment and
# allow-absent files are recorded by checkout-relative path and content digest.
# The variant NAME is not: it only selects the kernel_source block recorded
# here, and the orchestrator and a direct resolve.sh label it differently.
kernel_pin_source_json() {
  local file
  local -a args=(
    git_url "${git_url}" tag "${tag}" commit "${commit}"
    patches_git_url "${patches_url}" patches_commit "${patches_commit}"
    patches_series "${patches_series}" config_mode "${config_mode}"
    defconfig_base "${defconfig_base}" config_git_url "${config_git_url}"
    config_commit "${config_commit}" config_path "${config_path}"
    package "${kernel_pkg}"
    package_version "${package_version}" kernel_release "${kernel_release}"
    local_version "${local_version}" arch "${arch}"
  )
  for file in "${fragments[@]}"; do args+=(@fragment "${file}"); done
  [[ -z "${absent_list:-}" ]] || args+=(@absent "${absent_list}")
  python3 - "${PIPELINE_DIR}" "${args[@]}" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
args = sys.argv[2:]
def entry(path):
    p = pathlib.Path(path).resolve()
    try:
        name = str(p.relative_to(root))
    except ValueError:
        name = str(p)
    return {"path": name, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
source = {"fragments": [], "allow_absent": []}
for key, value in zip(args[0::2], args[1::2]):
    if key == "@fragment":
        source["fragments"].append(entry(value))
    elif key == "@absent":
        source["allow_absent"].append(entry(value))
    else:
        source[key] = value
print(json.dumps(source, sort_keys=True))
PY
}

# kernel_pin_check <pin> — the pin is well formed, names this package, and was
# produced from exactly the manifest's current source inputs.
kernel_pin_check() {
  local pin="$1" current
  current="$(kernel_pin_source_json)" || return 1
  python3 - "${pin}" "${KERNEL_PIN_FORMAT}" "${current}" "${kernel_pkg}_${package_version}_${arch}.deb" <<'PY'
import json, re, sys
pin_path, fmt, current, deb_name = sys.argv[1:]
hexd = re.compile(r'[0-9a-f]{64}')
try:
    pin = json.load(open(pin_path))
except (OSError, ValueError) as error:
    sys.exit(f'kernel pin {pin_path} unreadable: {error}')
problems = []
if pin.get('format') != fmt:
    problems.append(f"format {pin.get('format')!r}, expected {fmt!r}")
files = pin.get('sha256', {})
if set(files) != {deb_name, 'resolved.config', 'built-modules.txt'} or \
        not all(isinstance(v, str) and hexd.fullmatch(v) for v in files.values()):
    problems.append(f'sha256 must name {deb_name}, resolved.config and built-modules.txt')
artifact = pin.get('artifact', {})
if artifact.get('deb_sha256') != files.get(deb_name):
    problems.append('embedded kernel-artifact.json names a different deb')
for url in pin.get('sources', []):
    if not isinstance(url, str) or not (url.startswith('https://') or
                                        re.fullmatch(r'http://(127\.0\.0\.1|localhost):[0-9]{1,5}/.*', url)):
        problems.append(f'source {url!r} is not an HTTPS URL')
want, have = json.loads(current), pin.get('source', {})
for name in sorted(set(want) | set(have)):
    if want.get(name) != have.get(name):
        problems.append(f'source.{name}: pinned {have.get(name)!r}, manifest {want.get(name)!r}')
if problems:
    print(f'kernel pin {pin_path} does not match this build:', file=sys.stderr)
    for problem in problems:
        print(f'  - {problem}', file=sys.stderr)
    sys.exit(1)
PY
}

# kernel_pin_bytes_match <dir> <pin> — dir holds exactly the pinned bytes.
kernel_pin_bytes_match() {
  python3 - "$1" "$2" <<'PY'
import hashlib, json, pathlib, sys
root, pin = pathlib.Path(sys.argv[1]), json.load(open(sys.argv[2]))
try:
    ok = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
             for name, digest in pin['sha256'].items())
except OSError:
    ok = False
sys.exit(0 if ok else 1)
PY
}

# Candidate entries in the artifact cache whose manifest records the pinned
# digests, newest first. The entry's own key does not matter: the bytes do.
kernel_pin_cache_candidates() {
  local pin="$1" root
  root="$(kernel_artifact_cache_root)" || return 0
  [[ -d "${root}" ]] || return 0
  python3 - "${root}" "${pin}" <<'PY'
import json, pathlib, re, sys
root, pin = pathlib.Path(sys.argv[1]), json.load(open(sys.argv[2]))
found = []
for entry in root.iterdir():
    if not re.fullmatch(r'[0-9a-f]{64}', entry.name):
        continue
    try:
        manifest = json.loads((entry / 'manifest.json').read_text())
    except (OSError, ValueError):
        continue
    if manifest.get('sha256') == pin['sha256']:
        found.append((entry.stat().st_mtime, entry.name))
for _, name in sorted(found, reverse=True):
    print(name)
PY
}

kernel_pin_fetch_sources() {
  local pin="$1" dest="$2" deb_name="$3" base file
  command -v curl >/dev/null 2>&1 || return 1
  while read -r base; do
    [[ -n "${base}" ]] || continue
    rm -f -- "${dest}/"*
    for file in "${deb_name}" resolved.config built-modules.txt; do
      # Release-asset URLs redirect to a storage host; follow HTTPS redirects
      # only. Whatever arrives is re-hashed against the pin below.
      curl --fail --silent --show-error --proto '=https,http' --location --proto-redir '=https' \
        --max-redirs 5 --connect-timeout 10 --max-time 300 \
        -o "${dest}/${file}" "${base%/}/${file}" 2>/dev/null || continue 2
    done
    if kernel_pin_bytes_match "${dest}" "${pin}"; then
      printf '%s' "${base}"
      return 0
    fi
    log_warn "kernel pin source ${base} served bytes that differ from the pin; ignored"
  done < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get("sources", [])))' "${pin}")
  return 1
}

# kernel_pin_stage <pin> <out> — find the pinned bytes, verify them and stage
# them exactly like a build would. Returns 1 (nothing staged) when no trusted
# store has them or a candidate fails a gate.
kernel_pin_stage() {
  local pin="$1" out="$2" deb_name="${kernel_pkg}_${package_version}_${arch}.deb"
  local work origin="" root key
  work="$(mktemp -d)" || return 1
  root="$(kernel_artifact_cache_root)" || root=""
  while read -r key; do
    [[ -n "${key}" ]] || continue
    if (
      flock -w 3600 9 || exit 1
      for file in "${deb_name}" resolved.config built-modules.txt; do
        install -m 0644 "${root}/${key}/${file}" "${work}/${file}" || exit 1
      done
    ) 9>"${root}/.locks/${key}.lock" && kernel_pin_bytes_match "${work}" "${pin}"; then
      origin="artifact cache entry ${key}"
      break
    fi
  done < <([[ "$(kernel_artifact_cache_mode)" == auto ]] && kernel_pin_cache_candidates "${pin}")
  if [[ -z "${origin}" ]] && origin="$(kernel_pin_fetch_sources "${pin}" "${work}" "${deb_name}")"; then
    origin="pinned source ${origin}"
  fi
  if [[ -z "${origin}" ]]; then
    rm -rf -- "${work}"
    return 1
  fi
  if ! validate_built_kernel_deb "${work}/${deb_name}" "${kernel_pkg}" "${package_version}" "${arch}" "${dtb_path}" ||
     ! kernel_artifact_verify_config "${work}/resolved.config"; then
    log_warn "pinned kernel from ${origin} failed the deb or Kconfig gates; not used"
    rm -rf -- "${work}"
    return 1
  fi
  install -d -m 0755 "${out}" || { rm -rf -- "${work}"; return 1; }
  "${MKOSI_PACKAGE_STAGING_SH:-${HERE}/stage-mkosi-package.sh}" "${work}/${deb_name}" "${out}" || { rm -rf -- "${work}"; return 1; }
  install -m 0644 "${work}/resolved.config" "${out}/resolved.config" &&
  install -m 0644 "${work}/built-modules.txt" "${out}/built-modules.txt" &&
  python3 - "${pin}" "${out}/kernel-artifact.json" <<'PY' || { rm -rf -- "${work}"; return 1; }
import json, sys
record = dict(json.load(open(sys.argv[1]))['artifact'])
record['validated_boards'] = []  # re-earned by this build's own board gates
open(sys.argv[2], 'w').write(json.dumps(record, indent=2, sort_keys=True) + '\n')
PY
  rm -rf -- "${work}"
  log_success "kernel PINNED ${deb_name} sha256 $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"][sys.argv[2]])' "${pin}" "${deb_name}") from ${origin}; no compilation"
}

# kernel_pin_compare <out> <pin> — a compiled result must be the pinned kernel.
kernel_pin_compare() {
  local out="$1" pin="$2"
  if kernel_pin_bytes_match "${out}" "${pin}"; then
    log_success "kernel build reproduced the pin $(basename "${pin}") byte for byte"
    return 0
  fi
  log_error "kernel build differs from the pin $(basename "${pin}"):"
  (cd "${out}" && sha256sum -- "${kernel_pkg}_${package_version}_${arch}.deb" resolved.config built-modules.txt) >&2 || :
  return 1
}

# kernel_pin_write <built dir> <pin> [<source url>...] — record a kernel the
# producer just built (a --kernel-only output: deb, resolved.config,
# built-modules.txt, kernel-artifact.json) as the pin for this package_version.
kernel_pin_write() {
  # Not "commit": that name is the manifest's kernel commit in this frame.
  local built="$1" pin="$2" current pipeline_commit
  shift 2
  current="$(kernel_pin_source_json)" || return 1
  pipeline_commit="$(git -C "${PIPELINE_DIR}" rev-parse HEAD 2>/dev/null)" || pipeline_commit=""
  python3 - "${built}" "${pin}" "${KERNEL_PIN_FORMAT}" "${current}" \
    "${kernel_pkg}_${package_version}_${arch}.deb" "${pipeline_commit}" "$@" <<'PY'
import hashlib, json, pathlib, sys
built, pin, fmt, current, deb_name, commit, *sources = sys.argv[1:]
built = pathlib.Path(built)
artifact = json.loads((built / 'kernel-artifact.json').read_text())
files = {name: hashlib.sha256((built / name).read_bytes()).hexdigest()
         for name in (deb_name, 'resolved.config', 'built-modules.txt')}
if artifact.get('deb_sha256') != files[deb_name]:
    sys.exit('kernel-artifact.json does not describe this deb')
artifact = dict(artifact, validated_boards=[])
record = {'format': fmt, 'sha256': files, 'source': json.loads(current),
          'artifact': artifact, 'produced_by': {'pipeline_commit': commit},
          'sources': sources}
pathlib.Path(pin).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(pin).write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
PY
}
