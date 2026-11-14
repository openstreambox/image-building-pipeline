#!/usr/bin/env python3
"""Compile the board DTB from the exact applied candidate, without a kernel build."""
import importlib.util
import pathlib
import os
import subprocess
import sys
import tempfile
import yaml

root = pathlib.Path(__file__).resolve().parent.parent
kernel, patches = map(pathlib.Path, sys.argv[1:])
source = yaml.safe_load((root / 'manifests/families/rk3588.yaml').read_text())['variants']['edge']['kernel_source']

def git(tree, *args):
    return subprocess.check_output(['git', '-C', str(tree), *args], text=True).strip()

assert git(patches, 'rev-parse', 'HEAD') == source['patches_commit'], 'patch checkout differs from manifest'
series = [line for line in (patches / source['patches_series']).read_text().splitlines() if line and not line.startswith('#')]
assert any(line.startswith('0052-') for line in series), '0052 missing from active series'
# A fresh base plus every git-am commit, with no extra commits or dirty files.
assert git(kernel, 'rev-parse', f'HEAD~{len(series)}') == source['commit'], 'applied tree has a different base or series length'
assert not git(kernel, 'status', '--porcelain', '--untracked-files=no'), 'kernel tree is modified'
# Reapply each original mail patch to its parent in a disposable index and
# compare the resulting tree. Unlike patch-id, this tolerates changed diff
# context widths while proving the exact result of every applied payload.
with tempfile.TemporaryDirectory() as directory:
    env = dict(os.environ, GIT_INDEX_FILE=str(pathlib.Path(directory) / 'index'))
    for index, filename in enumerate(reversed(series)):
        commit = f'HEAD~{index}'
        def indexed(*args):
            return subprocess.check_output(['git', '-C', str(kernel), *args], env=env).strip()
        indexed('read-tree', commit + '^')
        indexed('apply', '--cached', '--whitespace=nowarn', str((patches / 'patches' / filename).resolve()))
        assert indexed('write-tree').decode() == git(kernel, 'rev-parse', commit + '^{tree}'), f'applied patch differs: {filename}'

spec = importlib.util.spec_from_file_location('cold_start', patches / 'tests/test_rock5bplus_wwan_cold_start.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.check_tree(kernel)
with tempfile.TemporaryDirectory() as directory:
    dtb = module.compile_dtb(kernel, pathlib.Path(directory))
    assert module.cells(dtb, '/rfkill-wwan', 'shutdown-gpios')[1:] == [6, 0], 'W_DISABLE1# polarity or pin changed'
    assert subprocess.check_output(['fdtget', str(dtb), '/rfkill-wwan', 'label'], text=True).strip() == 'rfkill-m2-wwan'
    assert 'default-blocked' not in module.props(dtb, '/rfkill-wwan')
# The GPIO consumer writes !blocked. With GPIO_ACTIVE_HIGH, unblocked is high.
assert 'gpiod_set_value_cansleep(rfkill->shutdown_gpio, !blocked);' in (kernel / 'net/rfkill/rfkill-gpio.c').read_text()
print(f'{len(series)} exact patches; compiled cold-start and rfkill GPIO contracts pass')
