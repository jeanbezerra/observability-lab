#!/usr/bin/env python3
"""Offline storage safety regressions: subprocesses and block devices are fake."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('storage', ROOT / 'installer-common/host-storage.py')
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)
GIB = 1024**3
MIB = 1024**2


class Inventory:
    def __init__(self, free=7*GIB, tail=0, part_type='part', root_type='lvm'):
        self.root_size = 55*GIB
        self.pv_size = 62*GIB
        self.tail = tail
        self.free = free
        self.root_type = root_type
        self.part_type = part_type
        self.calls = []

    def run(self, *cmd):
        self.calls.append(cmd)
        if cmd[0] == 'findmnt':
            return json.dumps({'filesystems': [{'source': '/dev/dm-0', 'fstype': 'ext4', 'options': 'rw,relatime'}]})
        if cmd[0] == 'lsblk':
            lv = {'name': 'dm-0', 'path': '/dev/dm-0', 'type': self.root_type, 'size': self.root_size, 'pkname': 'vda3'}
            return json.dumps({'blockdevices': [
                {'name': 'vda', 'path': '/dev/vda', 'type': 'disk', 'size': 64*GIB+2*MIB+self.tail, 'pkname': None,
                 'children': [{'name': 'vda3', 'path': '/dev/vda3', 'type': self.part_type, 'size': self.pv_size, 'pkname': 'vda', 'children': [lv]}]}]})
        if cmd[0] == 'lvs':
            return json.dumps({'report': [{'lv': [{'lv_path': '/dev/vg/root', 'vg_name': 'vg', 'lv_size': self.root_size,
                                                  'lv_attr': '-wi-ao----', 'segtype': 'linear'}]}]})
        if cmd[0] == 'pvs':
            return json.dumps({'report': [{'pv': [{'pv_name': '/dev/vda3', 'vg_name': 'vg', 'pv_size': self.pv_size-4*MIB}]}]})
        if cmd[0] == 'vgs':
            return json.dumps({'report': [{'vg': [{'vg_free': self.free}]}]})
        if cmd[:2] == ('sfdisk', '--json'):
            return json.dumps({'partitiontable': {'label': 'gpt', 'sectorsize': 512, 'partitions': [
                {'node': '/dev/vda1', 'start': 2048, 'size': 2048},
                {'node': '/dev/vda2', 'start': 4096, 'size': 2*GIB//512},
                {'node': '/dev/vda3', 'start': (2*GIB+2*MIB)//512, 'size': self.pv_size//512}]}})
        raise AssertionError('Unexpected external command ' + repr(cmd))

    def inspect(self):
        original = Path.read_text
        def read(path, *args, **kwargs):
            if str(path) == '/sys/class/block/vda3/partition': return '3\n'
            return original(path, *args, **kwargs)
        with patch.object(storage, 'run', self.run), patch.object(storage, 'filesystem_size', return_value=self.root_size), patch.object(Path, 'read_text', read):
            return storage.inspect()


class StorageTests(unittest.TestCase):
    def test_free_vg_is_not_already_used(self):
        state = Inventory().inspect()
        self.assertTrue(storage.pending(state))
        self.assertEqual(state['vg_free_bytes'], 7*GIB)

    def test_fully_allocated_root_has_no_expansion(self):
        self.assertFalse(storage.pending(Inventory(free=0).inspect()))

    def test_tail_space_is_detected(self):
        self.assertTrue(Inventory(tail=24*GIB).inspect()['grow_partition'])

    def test_gpt_and_metadata_alignment_is_not_unused_capacity(self):
        self.assertFalse(Inventory(free=0, tail=2*MIB).inspect()['grow_partition'])

    def test_raid_backing_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Backing device'): Inventory(part_type='raid1').inspect()

    def test_crypt_root_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'criptografada'): Inventory(root_type='crypt').inspect()

    def test_multiple_pvs_are_rejected_without_mutation(self):
        fixture = Inventory()
        original = fixture.run
        def run(*cmd):
            result = original(*cmd)
            if cmd[0] == 'pvs':
                data = json.loads(result); data['report'][0]['pv'].append({'pv_name': '/dev/vdb', 'vg_name': 'vg', 'pv_size': GIB});return json.dumps(data)
            return result
        fixture.run = run
        with self.assertRaisesRegex(ValueError, 'exatamente um PV'): fixture.inspect()
        self.assertFalse(any(c[0] in ['lvextend', 'pvresize', 'growpart'] for c in fixture.calls))

    def test_thin_pool_is_rejected(self):
        fixture = Inventory(); original = fixture.run
        def run(*cmd):
            result = original(*cmd)
            if cmd[0] == 'lvs':
                data=json.loads(result);data['report'][0]['lv'][0]['segtype']='thin';return json.dumps(data)
            return result
        fixture.run=run
        with self.assertRaisesRegex(ValueError, 'thin'): fixture.inspect()

    def test_other_last_partition_is_not_taken(self):
        fixture=Inventory(tail=GIB); original=fixture.run
        def run(*cmd):
            result=original(*cmd)
            if cmd[:2]==('sfdisk','--json'):
                data=json.loads(result);data['partitiontable']['partitions'][-1]['node']='/dev/vda4';return json.dumps(data)
            return result
        fixture.run=run
        with self.assertRaisesRegex(ValueError, 'última partição'): fixture.inspect()

    def test_interior_hole_is_not_repartitioned(self):
        fixture=Inventory(); original=fixture.run
        def run(*cmd):
            result=original(*cmd)
            if cmd[:2]==('sfdisk','--json'):
                data=json.loads(result);data['partitiontable']['partitions'][-1]['start']+=GIB//512;return json.dumps(data)
            return result
        fixture.run=run
        with self.assertRaisesRegex(ValueError, 'entre partições'): fixture.inspect()

    def test_only_filesystem_growth_is_detected(self):
        state=Inventory(free=0).inspect();state['filesystem_bytes']-=GIB
        self.assertTrue(storage.pending(state))

    def test_check_does_not_mutate(self):
        state=Inventory().inspect()
        with patch.object(storage,'inspect',return_value=state), patch.object(storage,'expand') as mutate, patch.object(sys,'argv',['host-storage.py','--check']):
            with self.assertRaisesRegex(ValueError,'espaço não aproveitado'):storage.main()
            mutate.assert_not_called()

    def test_expansion_can_be_disabled(self):
        with patch.object(storage,'inspect',return_value=Inventory().inspect()), patch.object(storage,'expand') as mutate, patch.object(sys,'argv',['host-storage.py','--auto-expand','false']):
            with self.assertRaises(ValueError):storage.main()
            mutate.assert_not_called()

    def test_missing_tool_blocks_before_backup_and_mutation(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(storage.shutil,'which',return_value=None), patch.object(storage,'run') as run:
            with self.assertRaisesRegex(ValueError,'Ferramentas prévias'):storage.expand(Inventory().inspect(),directory)
            run.assert_not_called();self.assertEqual(list(Path(directory).iterdir()),[])

    def test_backup_precedes_lvm_changes_and_growth_preserves_other_lvs(self):
        state=Inventory().inspect(); final=copy.deepcopy(state);final['vg_free_bytes']=0
        final['block_bytes']+=state['vg_free_bytes'];final['filesystem_bytes']=final['block_bytes']
        calls=[]
        def run(*cmd):
            calls.append(cmd)
            self.assertTrue(any(Path(directory).glob('*/before.json')))
            return 'label: gpt\n' if cmd[:2]==('sfdisk','--dump') else ''
        with tempfile.TemporaryDirectory() as directory, patch.object(storage.shutil,'which',return_value='/fake/tool'), patch.object(storage,'inspect',side_effect=[state,final]), patch.object(storage,'run',run), redirect_stdout(io.StringIO()):
            storage.expand(state,directory)
            self.assertLess(next(i for i,c in enumerate(calls) if c[0]=='vgcfgbackup'),next(i for i,c in enumerate(calls) if c[0]=='pvresize'))
            self.assertIn(('lvextend','-l','+100%FREE','-y','/dev/vg/root'),calls)
            self.assertFalse(any(c[0] in ['lvremove','pvcreate','mkfs','parted'] for c in calls))
            self.assertEqual(next(Path(directory).glob('*/before.json')).stat().st_mode & 0o777,0o600)

    def test_incomplete_resize_blocks_installation(self):
        state=Inventory().inspect()
        with tempfile.TemporaryDirectory() as directory, patch.object(storage.shutil,'which',return_value='/fake/tool'), patch.object(storage,'inspect',return_value=state), patch.object(storage,'run',return_value=''), redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(ValueError,'não consumiu'):storage.expand(state,directory)

    def test_vendored_helpers_are_identical(self):
        for project in ['keycloak','kubernetes','kubernetes-wsl','kubernetes-hml','ranher']:
            for name in ['host-preflight.sh','host-storage.py','windows-time.ps1']:
                self.assertEqual((ROOT/'installer-common'/name).read_bytes(),(ROOT/project/'scripts/lib'/name).read_bytes(),(project,name))


if __name__=='__main__':unittest.main()
