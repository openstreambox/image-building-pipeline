#!/usr/bin/env bash
# kernel/pinned.sh — reuse a SHA-pinned kernel artifact instead of compiling.
#
# Sourced by lib/kernel/released.sh, never executed. Like released.sh it sits
# OUTSIDE the producer fingerprint: it decides whether the producer runs, and it
# never changes what the producer builds.
#
# A pin (manifests/kernel/pins/<package_version>.json) names the exact bytes of
# one cold build (deb, resolved.config, built-modules.txt), every producer input
# that build used and the producer's own kernel-artifact.json record. The input
# set is the producer fingerprint's own list (kernel_input_values and
# kernel_input_files in kernel/artifact-cache.sh), so any change the cache key
# would notice also invalidates the pin. When the current inputs equal the pin's,
# the stage takes the pinned bytes from a trusted store instead of compiling:
#   1. the kernel artifact cache, looked up by content (skipped when
#      CERALIVE_KERNEL_ARTIFACT_CACHE=0);
#   2. the pin's "sources": HTTPS base URLs, such as a published release asset.
# Every candidate is re-hashed against the pin and then passes the same deb and
# Kconfig gates as a fresh build.
#
# CERALIVE_KERNEL_PIN
#   auto     (default) use the pinned artifact; if no store has it, compile and
#            require the result to equal the pin.
#   require  release builds: use the pinned artifact or stop. Never compiles.
#   verify   the periodic proof that the kernel still builds: always a COLD
#            compile (artifact cache off, fresh ccache, forced here), which must
#            reproduce the pinned bytes and the pinned builder record. Writes
#            kernel-pin-verify.json; CERALIVE_KERNEL_PIN_RECORD=1 also appends
#            the run to the pin's "reproduced" list.
#   write    create the pin: a COLD compile from committed, unmodified inputs.
#            Refuses an existing pin. CERALIVE_KERNEL_PIN_SOURCES (space
#            separated HTTPS base URLs) fills "sources".
#   0        ignore pins.
# A pin whose inputs differ from the current ones stops the build in every mode
# but 0 and write: the tree asks for a different kernel than the one pinned.
#
# shellcheck shell=bash
# shellcheck disable=SC2154

KERNEL_PIN_FORMAT='ceralive-kernel-pin/2'

kernel_pin_mode() {
  case "${CERALIVE_KERNEL_PIN:-auto}" in
    auto|require|verify|write|0) printf '%s' "${CERALIVE_KERNEL_PIN:-auto}" ;;
    *) die "CERALIVE_KERNEL_PIN must be auto, require, verify, write or 0 (got '${CERALIVE_KERNEL_PIN}')"; return 1 ;;
  esac
}

# A production build uses the reviewed in-tree pin only.
kernel_pin_file() {
  if [[ -n "${CERALIVE_KERNEL_PIN_DIR:-}" && "${CERALIVE_BUILD_MODE:-}" == production ]]; then
    die "CERALIVE_KERNEL_PIN_DIR is not honoured in production builds; the pin comes from manifests/kernel/pins"
    return 1
  fi
  printf '%s/%s.json' "${CERALIVE_KERNEL_PIN_DIR:-${PIPELINE_DIR}/manifests/kernel/pins}" "${package_version}"
}

kernel_pin_fetch_timeout() {
  local seconds="${CERALIVE_KERNEL_PIN_FETCH_TIMEOUT:-1800}"
  [[ "${seconds}" =~ ^[1-9][0-9]*$ ]] \
    || { die "CERALIVE_KERNEL_PIN_FETCH_TIMEOUT must be a positive number of seconds (got '${seconds}')"; return 1; }
  printf '%s' "${seconds}"
}

# The producer's inputs as canonical JSON: the scalar values known before the
# builder runs, and every input file by checkout-relative path and digest, in
# the fingerprint's order.
kernel_pin_inputs_json() {
  local values files
  values="$(kernel_input_values | base64 -w0)" || return 1
  files="$(kernel_input_files)" || return 1
  python3 - "${PIPELINE_DIR}" "${values}" "${files}" <<'PY'
import base64, hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
parts = base64.b64decode(sys.argv[2]).split(b'\0')[:-1]
values = {parts[i].decode(): parts[i + 1].decode() for i in range(0, len(parts), 2)}
files = []
for path in filter(None, sys.argv[3].split('\n')):
    p = pathlib.Path(path).resolve()
    try:
        name = str(p.relative_to(root))
    except ValueError:
        name = str(p)
    files.append({'path': name, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()})
print(json.dumps({'values': values, 'files': files}, sort_keys=True))
PY
}

# kernel_pin_check <pin> [--no-reproduction] — the pin is well formed, names
# this package, and was produced from exactly the current inputs. In a
# production build it must also carry a recorded independent cold verify
# (verify itself, which adds that record, passes --no-reproduction).
kernel_pin_check() {
  local pin="$1" current production=0
  [[ "${CERALIVE_BUILD_MODE:-}" != production || "${2:-}" == --no-reproduction ]] || production=1
  current="$(kernel_pin_inputs_json)" || return 1
  python3 - "${pin}" "${KERNEL_PIN_FORMAT}" "${current}" "${kernel_pkg}_${package_version}_${arch}.deb" "${production}" <<'PY'
import json, re, sys
pin_path, fmt, current, deb_name, production = sys.argv[1:]
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
if pin.get('artifact', {}).get('deb_sha256') != files.get(deb_name):
    problems.append('embedded kernel-artifact.json names a different deb')
if pin.get('produced_by', {}).get('cold') is not True:
    problems.append('the pin does not record a cold build')
if production == '1' and not any(
        isinstance(r, dict) and r.get('cold') is True and r.get('deb_sha256') == files.get(deb_name)
        for r in pin.get('reproduced', [])):
    problems.append('a production build needs the pin reproduced by at least one recorded independent cold verify')
for url in pin.get('sources', []):
    if not isinstance(url, str) or not (url.startswith('https://') or
                                        re.fullmatch(r'http://(127\.0\.0\.1|localhost):[0-9]{1,5}/.*', url)):
        problems.append(f'source {url!r} is not an HTTPS URL')
want, have = json.loads(current), pin.get('inputs', {})
wv, hv = want['values'], have.get('values', {})
for name in sorted(set(wv) | set(hv)):
    if wv.get(name) != hv.get(name):
        problems.append(f'input {name}: pinned {hv.get(name)!r}, now {wv.get(name)!r}')
wf = {f['path']: f['sha256'] for f in want['files']}
hf = {f.get('path'): f.get('sha256') for f in have.get('files', [])}
for path in sorted(set(wf) | set(hf)):
    if wf.get(path) != hf.get(path):
        problems.append(f'input file {path}: pinned {hf.get(path)}, now {wf.get(path)}')
if [f['path'] for f in want['files']] != [f.get('path') for f in have.get('files', [])] and \
        set(wf) == set(hf):
    problems.append('input file order differs (config fragments merge in order)')
if problems:
    print(f'kernel pin {pin_path} does not match this build:', file=sys.stderr)
    for problem in problems:
        print(f'  - {problem}', file=sys.stderr)
    sys.exit(1)
PY
}

# kernel_pin_tree_clean — the whole checkout is committed: no modified, staged
# or untracked file. Checking only the input files is not enough, because the
# manifests resolve.sh reads decide the source pins too.
kernel_pin_tree_clean() {
  local dirty
  git -C "${PIPELINE_DIR}" rev-parse --verify -q HEAD >/dev/null \
    || { log_error "kernel pin: ${PIPELINE_DIR} is not a git checkout"; return 1; }
  dirty="$(git -C "${PIPELINE_DIR}" status --porcelain --untracked-files=normal)" || return 1
  [[ -z "${dirty}" ]] && return 0
  log_error "kernel pin: the checkout has uncommitted changes:"
  printf '%s\n' "${dirty}" | head -20 >&2
  return 1
}

# The KERNEL_SOURCE_* fields the producer reads (lib/build-kernel.sh::main).
KERNEL_PIN_SOURCE_FIELDS=(GIT_URL TAG COMMIT PATCHES_GIT_URL PATCHES_COMMIT PATCHES_SERIES
  DEFCONFIG_BASE DEFCONFIG_FRAGMENT DEFCONFIG_FRAGMENTS CONFIG_GIT_URL CONFIG_COMMIT
  CONFIG_PATH CONFIG_ABSENT_SYMBOLS BUILDER_IMAGE LOCAL_VERSION KERNEL_RELEASE
  PACKAGE_VERSION DTB_DEB_DIR)

# kernel_pin_manifest_check <board> — the KERNEL_SOURCE_* values this build
# received are exactly what the committed manifest resolves to in a clean
# environment, so an environment override cannot be pinned or released.
kernel_pin_manifest_check() {
  local board="$1" resolved field name want bad=0
  resolved="$(env -i PATH="${PATH}" HOME="${HOME:-/}" LC_ALL=C.UTF-8 \
    "${PIPELINE_DIR}/lib/resolve.sh" "${board}" --variant "${CERALIVE_KERNEL_VARIANT:-default}")" \
    || { log_error "kernel pin: cannot resolve the committed manifest for ${board}"; return 1; }
  declare -A manifest=()
  while IFS= read -r -d '' field; do
    manifest["${field%%=*}"]="${field#*=}"
  done < <(
    eval "${resolved}" >/dev/null 2>&1 || exit 1
    for field in "${KERNEL_PIN_SOURCE_FIELDS[@]}"; do
      name="KERNEL_SOURCE_${field}"
      printf '%s=%s\0' "${name}" "${!name:-}"
    done
  )
  for field in "${KERNEL_PIN_SOURCE_FIELDS[@]}"; do
    name="KERNEL_SOURCE_${field}"
    want="${manifest[${name}]-<unresolved>}"
    if [[ "${!name:-}" != "${want}" ]]; then
      log_error "kernel pin: ${name} is '${!name:-}' in this build but '${want}' in the committed manifest"
      bad=1
    fi
  done
  return "${bad}"
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
  local pin="$1" dest="$2" deb_name="$3" base file timeout
  command -v curl >/dev/null 2>&1 || return 1
  timeout="$(kernel_pin_fetch_timeout)" || return 1
  while read -r base; do
    [[ -n "${base}" ]] || continue
    rm -f -- "${dest}/"*
    for file in "${deb_name}" resolved.config built-modules.txt; do
      # Release-asset URLs redirect to a storage host; follow HTTPS redirects
      # only. Whatever arrives is re-hashed against the pin below.
      curl --fail --silent --show-error --proto '=https,http' --location --proto-redir '=https' \
        --max-redirs 5 --connect-timeout 10 --max-time "${timeout}" \
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

# kernel_pin_publish <staged dir> <out> — move a complete, checked result into
# the stage's output directory; nothing reaches <out> before this point.
kernel_pin_publish() {
  local from="$1" out="$2" file
  install -d -m 0755 "${out}" || return 1
  for file in "${from}/"*; do
    mv -f -- "${file}" "${out}/" || return 1
  done
  rm -rf -- "${from}"
}

# kernel_pin_stage <pin> <dir> — find the pinned bytes, verify them and stage
# them into <dir> (a private directory) exactly like a build would. Returns 1
# when no trusted store has them or a candidate fails a gate.
kernel_pin_stage() {
  local pin="$1" out="$2" deb_name="${kernel_pkg}_${package_version}_${arch}.deb"
  local work origin="" root="" key
  work="$(mktemp -d)" || return 1
  if [[ "$(kernel_artifact_cache_mode)" == auto ]]; then
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
    done < <([[ -n "${root}" ]] && kernel_pin_cache_candidates "${pin}")
  fi
  if [[ -z "${origin}" ]] && origin="$(kernel_pin_fetch_sources "${pin}" "${work}" "${deb_name}")"; then
    origin="pinned source ${origin}"
  fi
  if [[ -z "${origin}" ]] ||
     ! validate_built_kernel_deb "${work}/${deb_name}" "${kernel_pkg}" "${package_version}" "${arch}" "${dtb_path}" ||
     ! kernel_artifact_verify_config "${work}/resolved.config"; then
    [[ -z "${origin}" ]] || log_warn "pinned kernel from ${origin} failed the deb or Kconfig gates; not used"
    rm -rf -- "${work}"
    return 1
  fi
  if ! "${MKOSI_PACKAGE_STAGING_SH:-${HERE}/stage-mkosi-package.sh}" "${work}/${deb_name}" "${out}" ||
     ! install -m 0644 "${work}/resolved.config" "${out}/resolved.config" ||
     ! install -m 0644 "${work}/built-modules.txt" "${out}/built-modules.txt" ||
     ! python3 - "${pin}" "${out}/kernel-artifact.json" <<'PY'
import json, sys
record = dict(json.load(open(sys.argv[1]))['artifact'])
record['validated_boards'] = []  # re-earned by this build's own board gates
open(sys.argv[2], 'w').write(json.dumps(record, indent=2, sort_keys=True) + '\n')
PY
  then
    rm -rf -- "${work}"
    return 1
  fi
  rm -rf -- "${work}"
  log_success "kernel PINNED ${deb_name} sha256 $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"][sys.argv[2]])' "${pin}" "${deb_name}") from ${origin}; no compilation"
}

# kernel_pin_compare <dir> <pin> [--record] — a compiled result must be the
# pinned kernel: the three files byte for byte, and with --record also the
# producer record (input fingerprint, kernel epoch, builder closure).
kernel_pin_compare() {
  local out="$1" pin="$2" full="${3:-}"
  if kernel_pin_bytes_match "${out}" "${pin}" &&
     { [[ "${full}" != --record ]] || python3 - "${out}/kernel-artifact.json" "${pin}" <<'PY'
import json, sys
built, pin = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))['artifact']
diff = [k for k in ('input_fingerprint', 'kernel_epoch', 'builder_closure', 'deb_sha256')
        if built.get(k) != pin.get(k)]
if diff:
    print('kernel build record differs from the pin in: ' + ', '.join(diff), file=sys.stderr)
    sys.exit(1)
PY
     }; then
    log_success "kernel build reproduced the pin $(basename "${pin}") byte for byte"
    return 0
  fi
  log_error "kernel build differs from the pin $(basename "${pin}"):"
  (cd "${out}" && sha256sum -- "${kernel_pkg}_${package_version}_${arch}.deb" resolved.config built-modules.txt) >&2 || :
  return 1
}

# kernel_pin_builder_id — the image id of the builder the producer just used.
kernel_pin_builder_id() {
  # The producer ran in a subshell; derive its builder tag the same way it does.
  "$(select_container_runtime)" image inspect --format '{{.Id}}' \
    "${KERNEL_BUILDER_IMAGE_TAG:-$(resolve_kernel_builder_tag "${builder_image}")}" 2>/dev/null || :
}

kernel_pin_commit_state() {
  local head
  head="$(git -C "${PIPELINE_DIR}" rev-parse HEAD 2>/dev/null)" || head=""
  printf '%s %s' "${head:-none}" "$(kernel_pin_tree_clean >/dev/null 2>&1 && printf clean || printf dirty)"
}

# kernel_pin_write <built dir> <pin> — record a cold build as the pin.
kernel_pin_write() {
  local built="$1" pin="$2" inputs state builder_id
  inputs="$(kernel_pin_inputs_json)" || return 1
  state="$(kernel_pin_commit_state)"
  builder_id="$(kernel_pin_builder_id)"
  # shellcheck disable=SC2086  # CERALIVE_KERNEL_PIN_SOURCES is a space-separated URL list
  python3 - "${built}" "${pin}" "${KERNEL_PIN_FORMAT}" "${inputs}" \
    "${kernel_pkg}_${package_version}_${arch}.deb" ${state} "${builder_id}" \
    ${CERALIVE_KERNEL_PIN_SOURCES:-} <<'PY'
import datetime, hashlib, json, pathlib, sys
built, pin, fmt, inputs, deb_name, commit, tree, builder_id, *sources = sys.argv[1:]
built = pathlib.Path(built)
artifact = json.loads((built / 'kernel-artifact.json').read_text())
files = {name: hashlib.sha256((built / name).read_bytes()).hexdigest()
         for name in (deb_name, 'resolved.config', 'built-modules.txt')}
if artifact.get('deb_sha256') != files[deb_name]:
    sys.exit('kernel-artifact.json does not describe this deb')
if tree != 'clean':
    sys.exit('refusing to pin a build from uncommitted inputs')
record = {
    'format': fmt, 'sha256': files, 'inputs': json.loads(inputs),
    'artifact': dict(artifact, validated_boards=[]),
    'produced_by': {'pipeline_commit': commit, 'builder_image_id': builder_id, 'cold': True,
                    'date': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')},
    'reproduced': [], 'sources': sources,
}
pathlib.Path(pin).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(pin).write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
PY
}

# kernel_pin_verify_record <built dir> <pin> — the verify run's own record, and
# with CERALIVE_KERNEL_PIN_RECORD=1 an entry in the pin's "reproduced" list.
kernel_pin_verify_record() {
  local built="$1" pin="$2" state builder_id
  state="$(kernel_pin_commit_state)"
  builder_id="$(kernel_pin_builder_id)"
  # shellcheck disable=SC2086  # two words: commit and tree state
  python3 - "${built}" "${pin}" "${CERALIVE_KERNEL_PIN_RECORD:-0}" ${state} "${builder_id}" <<'PY'
import datetime, json, pathlib, sys
built, pin, record_into_pin, commit, tree, builder_id = sys.argv[1:]
entry = {'date': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
         'pipeline_commit': commit, 'tree': tree, 'builder_image_id': builder_id,
         'cold': True, 'compiled': True, 'result': 'reproduced',
         'deb_sha256': json.loads((pathlib.Path(built) / 'kernel-artifact.json').read_text())['deb_sha256']}
(pathlib.Path(built) / 'kernel-pin-verify.json').write_text(json.dumps(entry, indent=2, sort_keys=True) + '\n')
if record_into_pin == '1':
    if tree != 'clean':
        sys.exit('CERALIVE_KERNEL_PIN_RECORD=1 needs committed, unmodified inputs')
    data = json.load(open(pin))
    data.setdefault('reproduced', []).append(entry)
    pathlib.Path(pin).write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
PY
}
