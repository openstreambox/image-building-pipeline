import importlib.util
import pathlib
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / 'mkosi/runtime/ceralive-clat.py'
spec = importlib.util.spec_from_file_location('clat', path)
clat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clat)

class Discovery(unittest.TestCase):
    def test_discovery(self):
        self.assertEqual(clat.prefix_from_answers(['2001:db8:64::c000:aa', '2001:db8:64::c000:ab']), '2001:db8:64::/96')
    def test_all_rfc6052_lengths(self):
        for length in (32,40,48,56,64,96):
            prefix = f'2001:db8::/{length}'
            self.assertEqual(clat.prefix_from_answers([clat.embed(prefix,a) for a in ['192.0.0.170','192.0.0.171']]), prefix)

    def test_confirmed_well_known(self):
        self.assertEqual(clat.prefix_from_answers(['64:ff9b::c000:aa', '64:ff9b::c000:ab']), '64:ff9b::/96')
    def test_no_guess(self):
        for answers in [[], ['2001:db8::1'], ['64:ff9b::c000:aa'], ['2001:db8::c000:aa', '2001:db9::c000:ab']]:
            with self.assertRaises(ValueError): clat.prefix_from_answers(answers)
    def test_short_prefix(self):
        self.assertEqual(clat.prefix_from_answers(['2001:db8:c000:aa::', '2001:db8:c000:ab::']), '2001:db8::/32')

class Admission(unittest.TestCase):
    def test_dual_stack_needs_no_clat(self):
        addresses = [dict(family='inet',scope='global',local='192.0.2.1'),dict(family='inet6',scope='global',local='2001:db8::1')]
        self.assertEqual(clat.eligible(addresses), [])

    def test_usable_ipv6_only(self):
        self.assertEqual(clat.eligible([dict(family='inet6',scope='global',local='2001:db8::1')]), ['2001:db8::1'])
        for flag in ['tentative','deprecated','dadfailed']:
            self.assertEqual(clat.eligible([dict(family='inet6',scope='global',local='2001:db8::1',**{flag: True})]), [])

    def test_link_state_lifecycle(self):
        from unittest.mock import patch
        made = []
        class Fake:
            def __init__(self, *args):
                self.undo = []; self.process = None; made.append(self)
            def start(self): self.undo.append('owned')
            def stop(self): self.undo.clear()
            def status(self,*args): pass
        with patch.object(clat, 'Link', Fake):
            controller = clat.Controller()
            controller.sync({'wan1': ('a','b',()), 'wan2': ('c','d',())})
            self.assertEqual(len(made), 2)
            controller.sync({'wan2': ('c','d',())})
            self.assertFalse(made[0].undo)
            self.assertTrue(made[1].undo)
            controller.sync({})
            self.assertFalse(made[1].undo)

if __name__ == '__main__': unittest.main()
