#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}
@test "status screen: qrencode output is parsed and drawn with a four-module quiet zone" {
  run python3 "$ROOT/tests/status-screen.test.py" QrTests
  [ "$status" -eq 0 ]
}
@test "status screen: only current, plain, allowlisted snapshot fields reach the page" {
  run python3 "$ROOT/tests/status-screen.test.py" SnapshotTests
  [ "$status" -eq 0 ]
}
@test "status screen: page fits the console and keeps the login line" {
  run python3 "$ROOT/tests/status-screen.test.py" PageTests FactTests TextTests UrlTests
  [ "$status" -eq 0 ]
}
@test "status screen: the renderer is installed and only the attention owner runs it" {
  run grep -Fq 'ceralive-status-screen.py" /usr/libexec/ceralive/ceralive-status-screen' "$ROOT/mkosi/customize/postinst.d/persistence.sh"
  [ "$status" -eq 0 ]
  run grep -rlF 'ceralive-status-screen' "$ROOT/mkosi" --include='*.service' --include='*.timer' --include='*.socket'
  [ -z "$output" ]
  run grep -Fq "STATUS_SCREEN = Path('/usr/libexec/ceralive/ceralive-status-screen')" "$ROOT/mkosi/runtime/ceralive-attention.py"
  [ "$status" -eq 0 ]
}
@test "status screen: qrencode is in the shared package list" {
  run grep -Eq '^[[:space:]]*qrencode([[:space:]]|$)' "$ROOT/manifests/packages/shared.list"
  [ "$status" -eq 0 ]
}
