"""Exercise the shipped policy with real jq and synthetic device/driver responses."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'mkosi/runtime/pipewire/ceralive-hdmirx-audio.sh'


class PolicyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, PATH=f'{self.root}:{os.environ["PATH"]}', FIXTURE=str(self.root))
        for name, body in {
            'v4l2-ctl': 'cat "$FIXTURE/controls"; exit "${CONTROL_RC:-0}"',
            'pw-dump': 'cat "$FIXTURE/devices"; exit "${DUMP_RC:-0}"',
            'pw-cli': 'printf "%s\\n" "$*" >> "$FIXTURE/calls"; exit "${SET_RC:-0}"',
        }.items():
            p = self.root / name
            p.write_text('#!/bin/bash\n' + body + '\n')
            p.chmod(0o755)
        self.controls(True)

    def controls(self, present):
        (self.root / 'controls').write_text(f'audio_present: {int(present)}\naudio_sampling_rate: {48000 if present else 0}\n')

    def card(self, identity='HDMIIN', current=0, stereo=False, id=71):
        profiles = [{'index': 0, 'name': 'off'}, {'index': 7, 'name': 'pro-audio'}]
        if stereo:
            profiles.append({'index': 12, 'name': 'input:stereo-fallback'})
        return {'id': id, 'type': 'PipeWire:Interface:Device', 'info': {
            'props': {'alsa.id': identity}, 'params': {
                'EnumProfile': profiles, 'Profile': [{'index': current}]}}}

    def run_policy(self, cards):
        (self.root / 'devices').write_text(json.dumps(cards))
        result = subprocess.run(['bash', str(SCRIPT), '--once'], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        p = self.root / 'calls'
        calls = p.read_text() if p.exists() else ''
        p.unlink(missing_ok=True)
        return calls

    def test_late_audio_activates_enumerated_fallback(self):
        self.assertEqual(self.run_policy([self.card()]), 'set-param 71 Profile { index: 7, save: false }\n')

    def test_stereo_preferred(self):
        self.assertIn('index: 12', self.run_policy([self.card(stereo=True)]))

    def test_absent_and_video_only_stay_off(self):
        self.controls(False)
        self.assertEqual(self.run_policy([self.card()]), '')
        (self.root / 'controls').write_text('audio_present: 0\naudio_sampling_rate: 48000\n')
        self.assertEqual(self.run_policy([self.card()]), '')

    def test_audio_loss_and_return(self):
        self.controls(False)
        self.assertIn('index: 0', self.run_policy([self.card(current=7)]))
        self.controls(True)
        self.assertIn('index: 7', self.run_policy([self.card()]))

    def test_missing_controls_fail_closed(self):
        self.env['CONTROL_RC'] = '1'
        self.assertIn('index: 0', self.run_policy([self.card(current=7)]))

    def test_zero_sample_rate_is_not_audio(self):
        (self.root / 'controls').write_text('audio_present: 1\naudio_sampling_rate: 0\n')
        self.assertEqual(self.run_policy([self.card()]), '')

    def test_other_cards_untouched_and_ids_not_fixed(self):
        calls = self.run_policy([self.card(identity='Analog'), self.card(id=93)])
        self.assertIn('set-param 93 ', calls)
        self.assertNotIn('set-param 71 ', calls)

    def test_no_repeated_write_and_daemon_restart(self):
        self.assertEqual(self.run_policy([self.card(current=7)]), '')
        self.assertIn('set-param 102 ', self.run_policy([self.card(id=102)]))

    def test_failed_set_retried_and_dump_failure_safe(self):
        self.env['SET_RC'] = '1'
        self.assertIn('set-param', self.run_policy([self.card()]))
        self.env['DUMP_RC'] = '1'
        self.assertEqual(self.run_policy([self.card()]), '')

    def test_unavailable_profile_not_selected(self):
        card = self.card()
        card['info']['params']['EnumProfile'][1]['available'] = 'no'
        self.assertEqual(self.run_policy([card]), '')


if __name__ == '__main__':
    unittest.main()
