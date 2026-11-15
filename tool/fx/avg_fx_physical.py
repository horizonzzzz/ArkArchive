"""从已解包 battle 与共享资源重建三种物理斩击（输入目录见 docs/story-player.md）。"""
import copy, json, shutil
from pathlib import Path
from avg_fx_mesh import select_prefab
from avg_fx_extract import convert


def read_tree(path):
    try:
        return next(iter(json.loads(path.read_bytes().decode('utf8', 'surrogateescape')).values()))
    except (OSError, ValueError, StopIteration) as error:
        raise ValueError(f'无法读取 typetree {path}：{error}') from error

source = Path('.temp/unpacked-battle/TT_battle.ab.json')
full = read_tree(source)
shared = {}
for file in Path('.temp/unpacked-fx-shared').rglob('TT_*.ab.json'):
    tree = read_tree(file)
    for pid, obj in tree.items():
        if 'm_SavedProperties' in obj or 'm_ForcedFallbackFormat' in obj:
            if pid in shared:
                raise ValueError(f'duplicate shared PathID {pid}')
            shared[pid] = (obj, file.parent)
shaders = {}
for file in (Path('.temp/unpacked-avg-shaders/TT_[uc]shaders.ab.json'), Path('.temp/unpacked-android-shaders/TT_[uc]shaders.ab.json')):
    tree = read_tree(file)
    shaders.update(tree)
for name in ('AVG_daoguang_attack_01_large', 'AVG_daoguang_attack_02_large', 'AVG_dao_attack_guiji_01'):
    selected = select_prefab(full, name)
    tree = {pid: copy.deepcopy(obj) for pid, obj in selected.items() if 'm_Component' in obj or 'm_GameObject' in obj}
    output = Path('.temp/fx-stage') / name.lower()
    output.mkdir(parents=True, exist_ok=True)
    def resolve(ref):
        pid, fid = str(ref.get('m_PathID', 0)), ref.get('m_FileID', 0)
        if pid == '0':
            return None
        if fid and pid in shared:
            obj, folder = shared[pid]
        elif not fid and pid in full:
            obj, folder = full[pid], source.parent
        else:
            return None
        if 'm_ForcedFallbackFormat' in obj:
            png = folder / (obj.get('m_Name', '') + '.png')
            if not png.exists():
                raise FileNotFoundError(png)
            shutil.copyfile(png, output / png.name)
        tree.setdefault(pid, copy.deepcopy(obj))
        ref['m_FileID'] = 0
        return tree[pid]
    for obj in list(tree.values()):
        for ref in obj.get('m_Materials', []):
            mat = resolve(ref)
            if mat:
                for _, tex in mat.get('m_SavedProperties', {}).get('m_TexEnvs', []):
                    resolve(tex['m_Texture'])
        if obj.get('m_Mesh'):
            resolve(obj['m_Mesh'])
    for obj in list(tree.values()):
        if 'm_Controller' in obj and 'm_GameObject' in obj:
            controller = resolve(obj['m_Controller'])
            if controller is None:
                raise ValueError('Animator Controller 未解析')
            for clip in controller.get('m_AnimationClips', []):
                if resolve(clip) is None:
                    raise ValueError('AnimationClip 未解析')
    staged = output / f'TT_{name.lower()}.ab.json'
    staged.write_text(json.dumps({'tree': tree}, ensure_ascii=True), encoding='utf8')
    data = convert(staged, Path('.temp/fx-stage-result'), name, shaders)
    data['drawAfterBlocker'] = True
    from avg_fx_json import dumps
    destination = Path('assets/fx-runtime/baked') / name.lower()
    destination.mkdir(parents=True, exist_ok=True)
    data_file = Path('.temp/fx-stage-result') / name.lower() / 'fx.json'
    data_file.write_text(dumps(data), encoding='utf8')
    shutil.copytree(data_file.parent, destination, dirs_exist_ok=True)
    print(name, 'emitters', [(e['name'], e['kind']) for e in data['emitters']], 'duration', data['duration'])