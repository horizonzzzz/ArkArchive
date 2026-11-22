"""从 battle.ab 与 sharedbattle 资源重建落沙特效。"""
import copy
import json
import shutil
from pathlib import Path

from avg_fx_extract import convert
from avg_fx_mesh import select_prefab


def read_tree(path):
    try:
        return next(iter(json.loads(path.read_bytes().decode('utf8', 'surrogateescape')).values()))
    except (OSError, ValueError, StopIteration) as error:
        raise ValueError(f'无法读取 typetree {path}: {error}') from error


def main():
    source = Path('.temp/unpacked-battle/TT_battle.ab.json')
    full = read_tree(source)
    shared_file = Path('.temp/unpacked-fx-shared/sharedbattle/TT_sharedbattle.ab.json')
    shared = {pid: (obj, shared_file.parent) for pid, obj in read_tree(shared_file).items()}

    name = 'AVG_035_sandfall_01'
    staging = Path('.temp/fx-stage') / name.lower()
    staging.mkdir(parents=True, exist_ok=True)
    tree = {pid: copy.deepcopy(obj) for pid, obj in select_prefab(full, name).items()
            if 'm_Component' in obj or 'm_GameObject' in obj}

    def resolve(ref):
        pid, file_id = str(ref.get('m_PathID', 0)), ref.get('m_FileID', 0)
        if pid == '0':
            return None
        if file_id and pid in shared:
            obj, folder = shared[pid]
        elif not file_id and pid in full:
            obj, folder = full[pid], source.parent
        else:
            return None
        if 'm_ForcedFallbackFormat' in obj:
            png = folder / f"{obj.get('m_Name', '')}.png"
            if not png.exists():
                raise FileNotFoundError(png)
            shutil.copyfile(png, staging / png.name)
        tree.setdefault(pid, copy.deepcopy(obj))
        ref['m_FileID'] = 0
        return tree[pid]

    for obj in list(tree.values()):
        for ref in obj.get('m_Materials', []):
            material = resolve(ref)
            if material:
                for _, texture in material.get('m_SavedProperties', {}).get('m_TexEnvs', []):
                    resolve(texture['m_Texture'])

    staged = staging / f'TT_{name.lower()}.ab.json'
    staged.write_text(json.dumps({'tree': tree}, ensure_ascii=True), encoding='utf8')
    shaders = read_tree(Path('.temp/unpacked-avg-shaders/TT_[uc]shaders.ab.json'))
    data = convert(staged, Path('assets/fx-runtime/particle'), name, shaders, project_particles=True)
    print(name, 'emitters', [(e['name'], e['kind']) for e in data['emitters']])


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, StopIteration) as error:
        raise SystemExit(f'落沙特效转换失败: {error}') from error
