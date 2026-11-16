#!/usr/bin/env bash
# Exercise the real entrypoint with isolated suites and command stubs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tests" "$work/lib/shared" "$work/bin"
cp "$ROOT/run-tests" "$work/"
cp "$ROOT/lib/shared/args-lib.sh" "$work/lib/shared/"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$work/tests/fixture.sh"
cp "$work/tests/fixture.sh" "$work/tests/real-avahi-hostname-contract.sh"
cp "$work/tests/fixture.sh" "$work/tests/rauc-rollback.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo shell-failure' 'exit 1' > "$work/tests/fail.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo later-shell-ran' > "$work/tests/later.sh"
printf '%s\n' '#!/usr/bin/env bash' 'if [[ "${1:-}" == --version ]]; then echo "Bats 1.12.0"; else echo bats-ran; exit "${FAKE_BATS_STATUS:-0}"; fi' > "$work/bin/bats"
touch "$work/tests/unit.bats"
chmod +x "$work"/tests/*.sh "$work/bin/bats"
printf '%s\n' \
  $'tests/unit.bats\tbats\tunit\tdefault-bats\tfixture' \
  $'tests/fail.sh\tshell\tunit\tdefault-shell\tfixture' \
  $'tests/later.sh\tshell\tunit\tdefault-shell\tfixture' \
  $'tests/fixture.sh\tfixture\tsupport\tdefault-fixture\tfixture' > "$work/tests/registry.tsv"
run_case() {
  local expected="$1" rc=0
  PATH="$work/bin:$PATH" BATS_JOBS=1 bash "$work/run-tests" > "$work/output" 2>&1 || rc=$?
  [[ "$rc" -eq "$expected" ]]
  grep -qx later-shell-ran "$work/output"
  grep -qx bats-ran "$work/output"
}
# A shell failure must remain red after the later shell suite and Bats run.
run_case 1
grep -q 'ERROR: shell suite failed:' "$work/output"
# A clean shell run must preserve the Bats exit status, including success.
cp "$work/tests/fixture.sh" "$work/tests/fail.sh"
FAKE_BATS_STATUS=9 run_case 9
FAKE_BATS_STATUS=0 run_case 0
printf 'run-tests failure reporting: PASS\n'
