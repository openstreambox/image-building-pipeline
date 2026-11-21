#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}
@test "attention console: unchanged fatal survives startup repaint on its own VT" {
  run python3 "$ROOT/tests/attention-console.test.py" ConsoleTests.test_startup_getty_and_unchanged_fatal ConsoleTests.test_watch_repaints_every_tick_and_releases_on_stop
  [ "$status" -eq 0 ]
}
@test "attention console: clear/expiry restores text, font and previous VT" {
  run python3 "$ROOT/tests/attention-console.test.py" ConsoleTests.test_info_clear_restores_font_and_login ConsoleTests.test_return_to_previous_vt_on_critical_clear_and_stop ConsoleTests.test_failed_save_never_changes_font_and_failed_restore_retries ConsoleTests.test_failed_switch_keeps_message_and_shortcut_until_retry
  [ "$status" -eq 0 ]
}
@test "attention console: login stays reachable through critical and process restart" {
  run python3 "$ROOT/tests/attention-console.test.py" ConsoleTests.test_login_remains_reachable_and_not_stolen ConsoleTests.test_restart_keeps_original_snapshot_and_does_not_steal_login ConsoleTests.test_warning_has_no_console_effect_and_long_detail_keeps_shortcut
  [ "$status" -eq 0 ]
}
@test "status page: VT8 shows it at boot in the 8x16 font, conditions take precedence" {
  run python3 "$ROOT/tests/attention-console.test.py" StatusConsoleTests.test_boot_shows_the_page_once_in_the_small_font StatusConsoleTests.test_critical_takes_over_and_the_page_returns StatusConsoleTests.test_condition_pulls_from_a_login_prompt_and_hands_it_back StatusConsoleTests.test_renderer_fault_keeps_the_login_line StatusConsoleTests.test_full_width_last_line_is_not_erased
  [ "$status" -eq 0 ]
}
@test "status page: boot and HDMI hotplug switch to VT8, never away from a logged-in operator" {
  run python3 "$ROOT/tests/attention-console.test.py" StatusConsoleTests.test_boot_switch_skips_a_logged_in_operator StatusConsoleTests.test_failed_boot_switch_retries_then_stops StatusConsoleTests.test_hdmi_plug_switches_unless_someone_is_logged_in StatusConsoleTests.test_restart_keeps_the_operator_where_they_are StatusConsoleTests.test_stop_returns_to_the_login_and_restores_the_font InputTests StatusConsoleTests.test_hdmi_plug_during_a_condition_does_not_switch StatusConsoleTests.test_unreadable_connector_is_not_a_plug StatusConsoleTests.test_stop_returns_to_the_vt_found_at_start_not_the_last_pull
  [ "$status" -eq 0 ]
}
@test "status page: earlier VT8 rules still hold with the page installed" {
  run python3 "$ROOT/tests/attention-console.test.py" StatusConsoleTests.test_startup_getty_and_unchanged_fatal StatusConsoleTests.test_login_remains_reachable_and_not_stolen StatusConsoleTests.test_restart_keeps_original_snapshot_and_does_not_steal_login
  [ "$status" -eq 0 ]
}
@test "status page: the owner loads the real renderer and survives a broken one" {
  run python3 "$ROOT/tests/attention-console.test.py" StatusPageTests
  [ "$status" -eq 0 ]
}
@test "attention console: never switches away from a login, never repeats a switch after a restart" {
  run python3 "$ROOT/tests/attention-console.test.py" ConsoleTests.test_condition_never_pulls_from_a_logged_in_vt ConsoleTests.test_service_restart_during_a_condition_never_pulls_again LegacyTests StatusConsoleTests.test_condition_never_pulls_from_a_logged_in_vt StatusConsoleTests.test_service_restart_during_a_condition_never_pulls_again
  [ "$status" -eq 0 ]
}
@test "attention console: unit reserves VT8 and starts independent rescue gettys first" {
  run python3 - "$ROOT" <<'PY'
from pathlib import Path
import configparser
import sys
root=Path(sys.argv[1])
unit=configparser.ConfigParser()
unit.read(root/'mkosi/runtime/ceralive-attention.service')
for login in ('getty@tty1.service','getty@tty2.service'):
    assert login in unit['Unit']['Wants'].split()
    assert login in unit['Unit']['After'].split()
for reserved in ('getty@tty8.service','autovt@tty8.service'):
    assert reserved in unit['Unit']['Conflicts'].split()
    assert reserved in unit['Unit']['Before'].split()
assert unit['Service']['RuntimeDirectoryPreserve']=='restart'
PY
  [ "$status" -eq 0 ]
}
