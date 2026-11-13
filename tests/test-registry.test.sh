#!/usr/bin/env bash
#
# test-registry.test.sh — the completeness contract for tests/registry.tsv.
#
# The registry is only worth having if it cannot silently disagree with reality,
# so this asserts BOTH directions:
#
#   forward   every tracked file under tests/ is registered, exactly once, with a
#             kind/tier/execution from the closed vocabularies and a reason
#   backward  every registered path exists on disk and is runnable as its kind
#             claims (a `default-bats` row that is not a readable .bats file, or a
#             `default-shell` row that is not executable, is a broken gate)
#   resolved  `./run-tests --list` equals the registry's default rows verbatim —
#             this is what makes "the registry describes the executed set" a
#             checked fact rather than a comment
#
# Non-vacuity: the forward check is re-run against a phantom file that is NOT in
# the registry and MUST fail. Without that leg a completeness test that silently
# scanned nothing would pass forever.
#
# Profile: contract-test (docs/shell-profiles.md) — `set -uo pipefail`, no `-e`,
# so every violation is reported in one run rather than only the first.
#
# Run:  bash tests/test-registry.test.sh   (exit 0 = all pass)
#
# shellcheck shell=bash

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "${HERE}/.." && pwd)"
REGISTRY="${HERE}/registry.tsv"
RUN_TESTS="${PIPELINE_DIR}/run-tests"

# shellcheck source=lib/assertions.sh
source "${HERE}/lib/assertions.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

VALID_KINDS=" bats shell helper fixture tool "
VALID_TIERS=" unit integration privileged hardware-gated support "
VALID_EXECUTIONS=" default-bats default-shell default-fixture default-mock opt-in ci-job invoked-by-suite not-executed "

echo "=============================================================="
echo " tests/registry.tsv — completeness and default-set contract"
echo "=============================================================="

# --- 0. the registry itself parses ----------------------------------------
echo
echo "### 0. registry schema"

if [[ -f "${REGISTRY}" ]]; then ok "registry exists at ${REGISTRY#"${PIPELINE_DIR}"/}"; else
  bad "registry missing at ${REGISTRY}"
  printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
  exit 1
fi

# Data rows only: comments and blank lines are stripped once, here.
grep -vE '^[[:space:]]*(#|$)' "${REGISTRY}" > "${WORK}/rows.tsv"
row_count="$(wc -l < "${WORK}/rows.tsv" | tr -d ' ')"
if [[ "${row_count}" -gt 0 ]]; then ok "registry has ${row_count} data rows"; else bad "registry has no data rows"; fi

bad_fields=0 bad_kind=0 bad_tier=0 bad_exec=0 no_reason=0
while IFS= read -r line; do
  IFS=$'\t' read -r -a f <<< "${line}"
  if [[ "${#f[@]}" -ne 5 ]]; then bad_fields=$((bad_fields + 1)); echo "    row has ${#f[@]} fields, want 5: ${line}"; continue; fi
  [[ "${VALID_KINDS}"      == *" ${f[1]} "* ]] || { bad_kind=$((bad_kind + 1)); echo "    bad kind '${f[1]}': ${f[0]}"; }
  [[ "${VALID_TIERS}"      == *" ${f[2]} "* ]] || { bad_tier=$((bad_tier + 1)); echo "    bad tier '${f[2]}': ${f[0]}"; }
  [[ "${VALID_EXECUTIONS}" == *" ${f[3]} "* ]] || { bad_exec=$((bad_exec + 1)); echo "    bad execution '${f[3]}': ${f[0]}"; }
  [[ -n "${f[4]// /}" ]] || { no_reason=$((no_reason + 1)); echo "    empty reason: ${f[0]}"; }
done < "${WORK}/rows.tsv"

assert_eq "every row has exactly 5 tab-separated fields" "0" "${bad_fields}"
assert_eq "every row's kind is from the closed vocabulary" "0" "${bad_kind}"
assert_eq "every row's tier is from the closed vocabulary" "0" "${bad_tier}"
assert_eq "every row's execution is from the closed vocabulary" "0" "${bad_exec}"
assert_eq "every row carries a non-empty reason" "0" "${no_reason}"

cut -f1 "${WORK}/rows.tsv" | LC_ALL=C sort > "${WORK}/registered.txt"
dupes="$(uniq -d < "${WORK}/registered.txt" | wc -l | tr -d ' ')"
assert_eq "no path is registered twice" "0" "${dupes}"

# Every privileged entry must guard itself, including direct invocation, unless
# it declares itself confined (all effects inside fixtures it creates). The
# confined set is fixed here, so widening it is a reviewed change: the real
# RAUC harness changes host mounts and partition labels and must stay guarded
# (marked guest, or a GitHub-hosted ephemeral runner VM on explicit opt-in).
confined_expected=$'tests/kernel-stage-real.test.sh\ntests/real-avahi-hostname-contract.sh'
confined_seen=() guarded_seen=() privileged_seen=()
while IFS=$'\t' read -r path _kind tier _execution _reason; do
  [[ "${tier}" == privileged ]] || continue
  guarded=0 confined=0
  privileged_seen+=("${path}")
  grep -Eq '^source "\$\{HERE\}/lib/require-(disposable-guest|ephemeral-host)\.sh"$' "${PIPELINE_DIR}/${path}" && guarded=1
  grep -Eq '^# guest-guard: confined\. .+' "${PIPELINE_DIR}/${path}" && confined=1
  if (( guarded && ! confined )); then
    ok "privileged harness sources guest guard: ${path}"
    guarded_seen+=("${path}")
  elif (( confined && ! guarded )); then
    ok "privileged harness declares confined effects: ${path}"
    confined_seen+=("${path}")
  else
    bad "privileged harness must either source the guest guard or declare itself confined: ${path}"
  fi
done <"${WORK}/rows.tsv"
assert_eq "confined privileged harnesses" "${confined_expected}" \
  "$(printf '%s\n' "${confined_seen[@]}" | LC_ALL=C sort)"
for path in tests/real-rauc-contract.sh tests/real-rauc-cleanup-contract.test.sh; do
  if grep -Fxq 'source "${HERE}/lib/require-ephemeral-host.sh"' "${PIPELINE_DIR}/${path}"; then
    ok "real RAUC harness sources the ephemeral-host guard: ${path}"
  else
    bad "real RAUC harness lacks the ephemeral-host guard: ${path}"
  fi
done

# The marked-guest workflow's header says which rows are guest-only. It must
# name exactly the guarded privileged harnesses by file name, so it cannot
# drift back to listing a confined row (which runs unguarded on the hosted job)
# or miss a newly guarded one.
guest_workflow="${PIPELINE_DIR}/.github/workflows/privileged-guest.yml"
guest_header="$(sed -n '/^#/!q;p' "${guest_workflow}")"
named=()
for path in "${privileged_seen[@]}"; do
  grep -Fq "$(basename "${path}")" <<<"${guest_header}" && named+=("${path}")
done
assert_eq "guest workflow header names exactly the guest-only rows" \
  "$(printf '%s\n' "${guarded_seen[@]}" | LC_ALL=C sort)" \
  "$(printf '%s\n' "${named[@]}" | LC_ALL=C sort)"

# Exercise only the shared guard, never a privileged harness. Substitute a
# temporary marker path in a copy so all four guest/marker combinations are safe.
sed "s|/sys/firmware/qemu_fw_cfg/by_name/opt/ceralive|${WORK}/guest-marker|g" \
  "${HERE}/lib/require-disposable-guest.sh" > "${WORK}/guard.sh"
for virt in none kvm; do
  for marker in absent present; do
    rm -rf "${WORK}/guest-marker"
    [[ "${marker}" != present ]] || mkdir "${WORK}/guest-marker"
    bash -c 'systemd-detect-virt() { echo "$1"; }; v="$1"; systemd-detect-virt() { echo "$v"; }; source "$2"' \
      guard "${virt}" "${WORK}/guard.sh" >"${WORK}/guard.log" 2>&1
    rc=$?
    expected=2
    [[ "${virt}" != kvm || "${marker}" != present ]] || expected=0
    assert_eq "guest guard ${virt}/${marker}" "${expected}" "${rc}"
  done
done

# The RAUC guard: a marked guest, or a GitHub-hosted runner VM on the explicit
# spelling. A copy of both guards with the temporary marker path; the runner
# variables are set per case, never inherited from a real CI job.
mkdir -p "${WORK}/lib"
cp "${WORK}/guard.sh" "${WORK}/lib/require-disposable-guest.sh"
cp "${HERE}/lib/require-ephemeral-host.sh" "${WORK}/lib/require-ephemeral-host.sh"
rauc_guard_case() { # <virt> <marker> <spelling> <github-actions> <runner-environment>
  rm -rf "${WORK}/guest-marker"
  [[ "$2" != present ]] || mkdir "${WORK}/guest-marker"
  env -u GITHUB_ACTIONS -u RUNNER_ENVIRONMENT -u CERALIVE_RUN_REAL_RAUC_CONTRACT \
    ${3:+CERALIVE_RUN_REAL_RAUC_CONTRACT=$3} ${4:+GITHUB_ACTIONS=$4} ${5:+RUNNER_ENVIRONMENT=$5} \
    bash -c 'v="$1"; systemd-detect-virt() { echo "$v"; }; export -f systemd-detect-virt; export v; source "$2"' \
    guard "$1" "${WORK}/lib/require-ephemeral-host.sh" >/dev/null 2>&1
}
#              virt      marker  spelling                 actions runner-env    expected
while read -r virt marker spelling actions runner expected; do
  [[ "${spelling}" != - ]] || spelling=""
  [[ "${actions}" != - ]] || actions=""
  [[ "${runner}" != - ]] || runner=""
  rauc_guard_case "${virt}" "${marker}" "${spelling}" "${actions}" "${runner}"
  assert_eq "RAUC guard ${virt}/${marker}/${spelling:-unset}/${actions:-unset}/${runner:-unset}" "${expected}" "$?"
done <<'CASES'
kvm       present -                        -    -            0
none      absent  github-hosted-ephemeral  true github-hosted 2
microsoft absent  github-hosted-ephemeral  true github-hosted 0
microsoft absent  -                        true github-hosted 2
microsoft absent  disposable-marked-guest-only true github-hosted 2
microsoft absent  github-hosted-ephemeral  true self-hosted  2
microsoft absent  github-hosted-ephemeral  -    github-hosted 2
kvm       absent  -                        -    -            2
CASES

# CI row selection reuses those guards: a marked guest or a GitHub-hosted runner
# VM runs the RAUC rows; anywhere else they are skipped visibly (never exit 2).
#            virt      marker  actions runner-env    expected
while read -r virt marker actions runner expected; do
  [[ "${actions}" != - ]] || actions=""
  [[ "${runner}" != - ]] || runner=""
  rm -rf "${WORK}/guest-marker" "${WORK}/ci.env"
  [[ "${marker}" != present ]] || mkdir "${WORK}/guest-marker"
  ( systemd-detect-virt() { echo "${virt}"; }; export -f systemd-detect-virt; export virt
    unset GITHUB_ACTIONS RUNNER_ENVIRONMENT
    [[ -z "${actions}" ]] || export GITHUB_ACTIONS="${actions}"
    [[ -z "${runner}" ]] || export RUNNER_ENVIRONMENT="${runner}"
    CERALIVE_GUEST_GUARD="${WORK}/guard.sh" GITHUB_STEP_SUMMARY="" \
      bash "${PIPELINE_DIR}/ci/privileged-contracts.sh" "${WORK}/ci.env" ) >"${WORK}/ci.log" 2>&1
  rc=$?
  case_name="${virt}/${marker}/${actions:-unset}/${runner:-unset}"
  assert_eq "CI row selection exits 0 (${case_name})" "0" "${rc}"
  assert_eq "CI row selection env (${case_name})" "CERALIVE_RUN_REAL_RAUC_CONTRACT=${expected}" "$(cat "${WORK}/ci.env")"
  if [[ "${expected}" == skip ]]; then
    if grep -Fq '::notice title=Privileged contracts::skipped: needs marked guest' "${WORK}/ci.log"; then
      ok "skipping runner shows skipped: needs marked guest (${case_name})"
    else
      bad "skipping runner hides the privileged skip (${case_name})"
    fi
  fi
done <<'CASES'
none      absent  -    -             skip
kvm       present -    -             disposable-marked-guest-only
microsoft absent  true github-hosted github-hosted-ephemeral
none      absent  true github-hosted skip
microsoft absent  true self-hosted   skip
CASES
workflow="${PIPELINE_DIR}/.github/workflows/v2-ci.yml"
if grep -Fq 'run: ci/privileged-contracts.sh "$GITHUB_ENV"' "${workflow}" \
  && ! grep -Eq 'CERALIVE_RUN_REAL_RAUC_CONTRACT=' "${workflow}"; then
  ok "hosted bats job selects the RAUC rows through ci/privileged-contracts.sh"
else
  bad "hosted bats job forces the RAUC rows instead of selecting them"
fi
# The confined rows ran as required on the hosted runner before the guard and
# must keep doing so; a skip there would mean they run in no CI at all.
for contract in AVAHI KERNEL_STAGE PRIVILEGE_DROP; do
  if grep -Eq "^ +CERALIVE_RUN_REAL_${contract}_CONTRACT=required " "${workflow}"; then
    ok "hosted bats job requires the ${contract} contract"
  else
    bad "hosted bats job no longer requires the ${contract} contract"
  fi
done

# --- 1. forward: every tracked tests/ file is registered -------------------
echo
echo "### 1. completeness — no tracked test file may be unregistered"

# check_complete <candidate-list-file> -> prints each unregistered path, returns
# the count. Factored out so the non-vacuity leg below can drive it with a
# deliberately-unregistered path.
check_complete() {
  LC_ALL=C comm -23 <(LC_ALL=C sort "$1") "${WORK}/registered.txt"
}

git -C "${PIPELINE_DIR}" ls-files 'tests/*' > "${WORK}/tracked.txt"
tracked_count="$(wc -l < "${WORK}/tracked.txt" | tr -d ' ')"
missing="$(check_complete "${WORK}/tracked.txt")"
missing_count="$(printf '%s' "${missing}" | grep -c . || true)"
[[ -z "${missing}" ]] || printf '    unregistered:\n%s\n' "${missing}"
assert_eq "all ${tracked_count} tracked tests/ files are registered" "0" "${missing_count}"

cp "${WORK}/tracked.txt" "${WORK}/tracked-plus-phantom.txt"
echo 'tests/zz-phantom-unregistered.test.sh' >> "${WORK}/tracked-plus-phantom.txt"
phantom_count="$(check_complete "${WORK}/tracked-plus-phantom.txt" | grep -c . || true)"
assert_eq "NON-VACUITY: an unregistered test file is reported" "1" "${phantom_count}"

# --- 2. backward: every registered path exists and is runnable -------------
echo
echo "### 2. every registered path exists on disk and matches its kind"

absent=0 not_exec=0 not_bats=0 outside=0
while IFS=$'\t' read -r path kind _tier execution _reason; do
  [[ -e "${PIPELINE_DIR}/${path}" ]] || { absent=$((absent + 1)); echo "    absent: ${path}"; continue; }
  case "${path}" in
    tests/*) ;;
    mkosi/platform/boot/test-fallback.sh|mkosi/platform/x86/test-x86-fallback.sh|mkosi/customize/test-quirks.sh) ;;
    *) outside=$((outside + 1)); echo "    registered path outside tests/ and not a known platform harness: ${path}" ;;
  esac
  case "${execution}" in
    default-bats)
      [[ "${path}" == *.bats && -r "${PIPELINE_DIR}/${path}" ]] || { not_bats=$((not_bats + 1)); echo "    not a readable .bats suite: ${path}"; }
      ;;
    default-shell|default-fixture|default-mock|opt-in|ci-job)
      [[ -x "${PIPELINE_DIR}/${path}" ]] || { not_exec=$((not_exec + 1)); echo "    not executable: ${path}"; }
      ;;
  esac
  [[ "${kind}" != "bats" || "${path}" == *.bats ]] || { not_bats=$((not_bats + 1)); echo "    kind=bats but not a .bats file: ${path}"; }
done < "${WORK}/rows.tsv"

assert_eq "every registered path exists on disk" "0" "${absent}"
assert_eq "every registered path is under tests/ or a known platform harness" "0" "${outside}"
assert_eq "every executed non-bats row is executable" "0" "${not_exec}"
assert_eq "every bats row is a readable .bats suite" "0" "${not_bats}"

# --- 3. the registry IS the default executed set ---------------------------
echo
echo "### 3. run-tests --list equals the registry's default rows"

awk -F'\t' '$4 == "default-bats"  { printf "bats\t%s\n",  $1 }' "${WORK}/rows.tsv"  > "${WORK}/expected.txt"
awk -F'\t' '$4 == "default-shell" { printf "shell\t%s\n", $1 }' "${WORK}/rows.tsv" >> "${WORK}/expected.txt"

if [[ -x "${RUN_TESTS}" ]]; then ok "run-tests entrypoint is executable"; else bad "run-tests entrypoint is not executable"; fi

"${RUN_TESTS}" --list > "${WORK}/listed.txt" 2>"${WORK}/listed.err"
list_rc=$?
assert_eq "run-tests --list exits 0" "0" "${list_rc}"

if diff -u "${WORK}/expected.txt" "${WORK}/listed.txt" > "${WORK}/list.diff"; then
  ok "run-tests --list is byte-identical to the registry's default rows"
else
  bad "run-tests --list drifted from the registry"
  cat "${WORK}/list.diff"
fi

fixture_rows="$(awk -F'\t' '$4 == "default-fixture"' "${WORK}/rows.tsv" | wc -l | tr -d ' ')"
assert_eq "exactly one default-fixture row (the RAUC PKI generator)" "1" "${fixture_rows}"

# --- 4. run-tests no longer hardcodes a suite list -------------------------
echo
echo "### 4. run-tests reads the registry instead of hardcoding suites"

assert_contains "run-tests references tests/registry.tsv" "${RUN_TESTS}" 'tests/registry.tsv'
hardcoded="$(grep -cE '^\s*"\$\{HERE\}/tests/.*\.(bats|test\.sh)"\s*$' "${RUN_TESTS}" || true)"
assert_eq "no hardcoded suite-path array entries remain in run-tests" "0" "${hardcoded}"

echo
echo "=============================================================="
printf ' RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "=============================================================="
[[ "${FAIL}" -eq 0 ]]
