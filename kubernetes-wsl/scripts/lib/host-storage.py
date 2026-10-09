#!/usr/bin/env python3
"""Inspect and grow only the block-device chain of the mounted root filesystem."""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

TOLERANCE = 8 * 1024 * 1024  # Alignment, GPT headers and LVM metadata.


def run(*args):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, timeout=120)
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or '').strip()
        raise ValueError('%s falhou (código %s)%s' %
                         (args[0], error.returncode, ': ' + detail if detail else '.')) from error


def number(value):
    return int(float(str(value).strip()))


def flatten(nodes):
    result = {}
    for node in nodes:
        result[os.path.realpath(node['path'])] = node
        result.update(flatten(node.get('children', [])))
    return result


def filesystem_size(fstype):
    if fstype == 'ext4':
        root = json.loads(run('findmnt', '-J', '-n', '-o', 'SOURCE', '/'))['filesystems'][0]['source']
        output = run('dumpe2fs', '-h', root)
        count = re.search(r'^Block count:\s+(\d+)', output, re.M)
        size = re.search(r'^Block size:\s+(\d+)', output, re.M)
        if not count or not size:
            raise ValueError('Não foi possível medir o filesystem ext4 da raiz.')
        return int(count[1]) * int(size[1])
    if fstype == 'xfs':
        match = re.search(r'^data\s+=\s+bsize=(\d+)\s+blocks=(\d+)', run('xfs_info', '/'), re.M)
        if not match:
            raise ValueError('Não foi possível medir o filesystem XFS da raiz.')
        return int(match[1]) * int(match[2])
    raise ValueError('Raiz exige ext4 ou XFS; layout não será alterado automaticamente.')


def lvm_report(command, fields, section, *extra):
    data = json.loads(run(command, '--reportformat', 'json', '--units', 'b', '--nosuffix', '-o', fields, *extra))
    return data['report'][0][section]


def root_logical_volume(source):
    device = os.stat(source)
    if not stat.S_ISBLK(device.st_mode):
        raise ValueError('O dispositivo raiz não é um dispositivo de bloco.')
    identity = (os.major(device.st_rdev), os.minor(device.st_rdev))
    # /dev/dm-N is a kernel device name, not a VG/LV selector for lvs.
    # Match the active LV by device identity, independent of names and symlinks.
    volumes = lvm_report('lvs', 'lv_path,vg_name,lv_size,lv_attr,segtype,lv_kernel_major,lv_kernel_minor', 'lv')
    matches = [lv for lv in volumes
               if (number(lv['lv_kernel_major']), number(lv['lv_kernel_minor'])) == identity]
    if len(matches) != 1:
        raise ValueError('Não foi possível identificar um único LV ativo para a raiz %s (%s:%s); '
                         'nenhum volume será expandido.' % (source, *identity))
    return matches[0]


def inspect():
    root = json.loads(run('findmnt', '-J', '-n', '-o', 'SOURCE,FSTYPE,OPTIONS', '/'))['filesystems'][0]
    source = os.path.realpath(root['source'])
    if not source.startswith('/dev/') or 'rw' not in root['options'].split(','):
        raise ValueError('A raiz não é um dispositivo de bloco local gravável; instalação bloqueada.')
    devices = flatten(json.loads(run('lsblk', '-J', '-b', '-o', 'NAME,PATH,TYPE,SIZE,PKNAME'))['blockdevices'])
    node = devices.get(source)
    if not node:
        raise ValueError('Dispositivo raiz não encontrado no inventário de discos.')
    state = {'source': source, 'fstype': root['fstype'], 'block_bytes': number(node['size']),
             'filesystem_bytes': filesystem_size(root['fstype']), 'grow_partition': False,
             'grow_pv': False, 'vg_free_bytes': 0}
    backing = source
    if node['type'] == 'lvm':
        lv = root_logical_volume(source)
        if lv['segtype'].strip() != 'linear' or not lv['lv_attr'].startswith('-'):
            raise ValueError('LVM thin/snapshot/RAID não admite expansão automática nesta instalação.')
        state['lv_path'] = lv['lv_path'].strip()
        state['vg_name'] = lv['vg_name'].strip()
        pvs = [p for p in lvm_report('pvs', 'pv_name,vg_name,pv_size', 'pv')
               if p['vg_name'].strip() == state['vg_name']]
        if len(pvs) != 1:
            raise ValueError('O VG da raiz deve ter exatamente um PV; revise o layout antes de instalar.')
        backing = os.path.realpath(pvs[0]['pv_name'].strip())
        if backing not in devices:
            raise ValueError('PV da raiz não encontrado no inventário de discos.')
        state['pv_path'] = backing
        state['grow_pv'] = number(devices[backing]['size']) - number(pvs[0]['pv_size']) > TOLERANCE
        state['vg_free_bytes'] = number(lvm_report('vgs', 'vg_free', 'vg', state['vg_name'])[0]['vg_free'])
    elif node['type'] not in ('part', 'disk'):
        raise ValueError('Raiz criptografada, RAID, multipath ou layout desconhecido: ajuste manual necessário.')
    node = devices[backing]
    if node['type'] == 'part':
        parent = '/dev/' + node['pkname']
        disk = devices.get(os.path.realpath(parent))
        if not disk or disk['type'] != 'disk':
            raise ValueError('Partição raiz/PV não pertence diretamente a um disco simples.')
        state['disk_path'] = disk['path']
        state['partition_path'] = backing
        state['partition_number'] = int(Path('/sys/class/block', Path(backing).name, 'partition').read_text())
        table = json.loads(run('sfdisk', '--json', disk['path']))['partitiontable']
        if table['label'] not in ('gpt', 'dos'):
            raise ValueError('Tabela de partições não suportada.')
        sector = number(table.get('sectorsize', 512))
        partitions = sorted(table['partitions'], key=lambda p: number(p['start']))
        previous_end = 0
        for part in partitions:
            start = number(part['start']) * sector
            # Moving other partitions to fill an interior hole is never automatic.
            if start - previous_end > TOLERANCE:
                raise ValueError('Há espaço não alocado antes/entre partições; não é seguro mover partições automaticamente.')
            previous_end = start + number(part['size']) * sector
        tail = number(disk['size']) - previous_end
        if tail > TOLERANCE:
            if os.path.realpath(partitions[-1]['node']) != backing:
                raise ValueError('A última partição do disco não é a raiz/PV; espaço livre exige ajuste manual.')
            state['grow_partition'] = True
    elif node['type'] != 'disk':
        raise ValueError('Backing device da raiz não é disco ou partição simples.')
    return state


def pending(state):
    return (state['grow_partition'] or state['grow_pv'] or state['vg_free_bytes'] > 0
            or state['block_bytes'] - state['filesystem_bytes'] > 1024 * 1024)


def prepare_tools(state):
    needed = []
    if state['grow_partition']:
        needed.extend(['growpart', 'sfdisk', 'udevadm'])
    if state.get('pv_path'):
        needed.extend(['vgcfgbackup', 'pvresize', 'lvextend'])
    needed.append('resize2fs' if state['fstype'] == 'ext4' else 'xfs_growfs')
    missing = [name for name in needed if not shutil.which(name)]
    if missing:
        raise ValueError('Ferramentas prévias ausentes: ' + ', '.join(missing)
                         + '. Prepare-as na imagem do Ubuntu antes de executar o instalador.')


def expand(state, backup_root):
    prepare_tools(state)  # Validate the entire chain before the first mutation.
    timestamp = datetime.datetime.now().astimezone().strftime('%Y%m%d-%H%M%S%z')
    backup = Path(backup_root) / ('root-storage-' + timestamp + '-' + str(os.getpid()))
    backup.mkdir(parents=True, mode=0o700)
    backup.chmod(0o700)
    (backup / 'before.json').write_text(json.dumps(state, indent=2))
    if state.get('vg_name'):
        run('vgcfgbackup', '-f', str(backup / 'vg-before.conf'), state['vg_name'])
    if state.get('disk_path'):
        (backup / 'partition-table.sfdisk').write_text(run('sfdisk', '--dump', state['disk_path']))
    for file in backup.iterdir():
        file.chmod(0o600)
    print('Backup de disco/LVM: ' + str(backup), flush=True)
    if state['grow_partition']:
        run('growpart', state['disk_path'], str(state['partition_number']))
        run('udevadm', 'settle', '--timeout=30')
        after = inspect()
        if after['grow_partition']:
            raise ValueError('Partição ainda não cresceu no kernel; reinicie a VM e execute novamente. Backup preservado.')
    if state.get('pv_path'):
        run('pvresize', state['pv_path'])
        after = inspect()
        if after['vg_free_bytes'] > 0:
            run('lvextend', '-l', '+100%FREE', '-y', state['lv_path'])
    if state['fstype'] == 'ext4':
        run('resize2fs', state['source'])
    else:
        run('xfs_growfs', '/')
    final = inspect()
    if pending(final):
        raise ValueError('A expansão não consumiu todo o espaço elegível; instalação bloqueada.')
    (backup / 'after.json').write_text(json.dumps(final, indent=2))
    (backup / 'after.json').chmod(0o600)
    return final


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--auto-expand', choices=['true', 'false'], default='true')
    parser.add_argument('--backup-dir', default='/var/lib/installer-host/backups')
    args = parser.parse_args()
    os.environ['LC_ALL'] = 'C'
    state = inspect()
    if pending(state):
        if args.check or args.auto_expand == 'false':
            raise ValueError('Existe espaço não aproveitado no disco/PV/VG/filesystem raiz; a instalação exige expansão.')
        if os.geteuid() != 0:
            raise ValueError('Expansão da raiz exige root.')
        state = expand(state, args.backup_dir)
    print('Disco raiz integralmente aproveitado: %.2f GiB; livre: %.2f GiB.' %
          (state['block_bytes'] / 1024**3, shutil.disk_usage('/').free / 1024**3))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        print('ERRO de disco: ' + str(error), file=sys.stderr)
        sys.exit(1)
