"""把 ArkUnpacker 的 TT_*.ab.json 和 PNG 转为外部 AVG 特效目录。

用法：uv run --no-project python tool/avg_fx_extract.py <解包目录> <输出目录>
基础转换只用标准库；--prefab 材质烘焙需要 Pillow。原始 AssetBundle 和 typetree 不发布。
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil


# 当前 painter 尚未实现这些 shader 辅助贴图，直接绘制会把 mask 本身显示出来。
UNSUPPORTED_MAIN_TEXTURES = {
    'AVG_daoguang_06.png',
    'AVG_flow_02.png',
    'AVG_fire_09.png',
    'AVG_fire_13.png',
}

def curve(raw):
    raw = raw or {}
    def keys(value):
        return [[p['time'], p['value'], p.get('inSlope', 0), p.get('outSlope', 0)]
                for p in (value or {}).get('m_Curve', [])]
    return {'state': raw.get('minMaxState', 0),
            'scalar': raw.get('scalar', 0), 'min': raw.get('minScalar', 0),
            'curve': keys(raw.get('maxCurve')), 'curveMin': keys(raw.get('minCurve'))}


def gradient(raw):
    raw = raw or {}
    colors = [(raw.get(f'ctime{i}', 0) / 65535, raw[f'key{i}'])
              for i in range(raw.get('m_NumColorKeys', 0))]
    alphas = [(raw.get(f'atime{i}', 0) / 65535, raw[f'key{i}']['a'])
              for i in range(raw.get('m_NumAlphaKeys', 0))]
    def sample(keys, time, fallback):
        if not keys:
            return fallback
        keys = sorted(keys)
        if time <= keys[0][0]:
            return keys[0][1]
        for (ta, a), (tb, b) in zip(keys, keys[1:]):
            if time <= tb:
                k = (time - ta) / (tb - ta) if tb > ta else 0
                return a + (b - a) * k
        return keys[-1][1]
    stops = sorted({0.0, 1.0} | {t for t, _ in colors + alphas})
    return [[t, *[sample([(u, c[ch]) for u, c in colors], t, 1)
                  for ch in ('r', 'g', 'b')], sample(alphas, t, 1)] for t in stops]


def particle_gradient(raw):
    raw = raw or {}
    if raw.get('minMaxState', 0) == 0:
        color = raw.get('maxColor', dict(r=1, g=1, b=1, a=1))
        return [[t, *[color[c] for c in 'rgba']] for t in (0, 1)]
    return gradient(raw.get('maxGradient'))


def path_id(ref):
    # 外部对象的 PathID 不属于当前 bundle，不能误用本地同 ID 对象。
    return str(ref.get('m_PathID')) if ref and not ref.get('m_FileID') else ''


def convert(source, output, prefab=None, shaders=None):
    name = (prefab or source.name[3:-8]).lower()
    if not re.fullmatch(r'[a-z0-9_-]+', name):
        raise ValueError(f'无效特效名：{name}')
    try:
        tree = next(iter(json.loads(source.read_bytes().decode('utf-8', 'surrogateescape')).values()))
    except (OSError, ValueError, StopIteration) as error:
        raise ValueError(f'无法读取 typetree {source}：{error}') from error
    if prefab:
        from avg_fx_mesh import select_prefab
        tree = select_prefab(tree, prefab)
    transforms = {path_id(o.get('m_GameObject')): o for o in tree.values()
                  if 'm_LocalPosition' in o}
    def obj(ref):
        return tree.get(path_id(ref), {})
    def transform(t):
        p, s, r = t['m_LocalPosition'], t['m_LocalScale'], t['m_LocalRotation']
        pos, scale = [p['x'], p['y']], [s['x'], s['y']]
        angle = math.atan2(2 * (r['w'] * r['z'] + r['x'] * r['y']),
                           1 - 2 * (r['y'] ** 2 + r['z'] ** 2))
        parent = obj(t.get('m_Father'))
        if parent:
            pp, ps, pr = transform(parent)
            x, y = pos[0] * ps[0], pos[1] * ps[1]
            pos = [pp[0] + x * math.cos(pr) - y * math.sin(pr),
                   pp[1] + x * math.sin(pr) + y * math.cos(pr)]
            scale = [scale[0] * ps[0], scale[1] * ps[1]]
            angle += pr
        return pos, scale, angle
    def active(go):
        t = transforms.get(go)
        while t:
            if not obj(t.get('m_GameObject')).get('m_IsActive', True):
                return False
            t = obj(t.get('m_Father'))
        return True
    used = set()
    def material(raw):
        props = raw.get('m_SavedProperties', {})
        textures = dict(props.get('m_TexEnvs') or [])
        colors = dict(props.get('m_Colors') or [])
        floats = dict(props.get('m_Floats') or [])
        tex = obj(textures.get('_MainTex', {}).get('m_Texture'))
        filename = tex.get('m_Name', '') + '.png' if tex else ''
        if not filename or Path(filename).name != filename:
            raise ValueError(f'{name}：材质 {raw.get("m_Name")} 缺少本地 MainTex')
        if filename in UNSUPPORTED_MAIN_TEXTURES:
            raise ValueError(f'{name}：当前未实现 shader 辅助贴图 {filename}')
        used.add(filename)
        def color(key):
            c = colors.get(key, dict(r=1, g=1, b=1, a=1))
            return [c[k] for k in ('r', 'g', 'b', 'a')]
        uv = colors.get('_UVTween', {})
        return {'main': filename, 'tint': color('_TintColor'),
                'mainColor': color('_MainColor'),
                'uvScroll': [uv.get('r', 0), uv.get('g', 0)],
                'srcBlend': floats.get('_SrcBlend', 5),
                'dstBlend': floats.get('_DstBlend', 10)}
    systems = {path_id(o.get('m_GameObject')): o for o in tree.values() if 'InitialModule' in o}
    emitters = []
    for renderer in tree.values():
        if not renderer.get('m_Materials') or not renderer.get('m_Enabled', True):
            continue
        go = path_id(renderer.get('m_GameObject'))
        if go not in transforms or not active(go):
            continue
        mats = [obj(ref) for ref in renderer['m_Materials']]
        if not mats or not mats[0]:
            continue
        pos, scale, angle = transform(transforms[go])
        ps = systems.get(go)
        try:
            mat = material(mats[0])
        except ValueError as error:
            print(f'{source}: 跳过不支持的材质：{error}')
            continue
        entry = {'name': tree.get(go, {}).get('m_Name', ''),
                 'kind': 'particle' if ps else 'mesh',
                 'position': pos, 'scale': scale, 'rotation': angle,
                 'material': mat,
                 'sorting': renderer.get('m_SortingOrder', 0)}
        if ps:
            im = ps['InitialModule']
            shape, uv = ps['ShapeModule'], ps['UVModule']
            radius = shape.get('radius', 0)
            if isinstance(radius, dict):
                radius = radius.get('value', 0)
            shscale = shape.get('m_Scale', {})
            size, color = ps['SizeModule'], ps['ColorModule']
            rot, vel, noise = ps['RotationModule'], ps['VelocityModule'], ps['NoiseModule']
            entry.update(loop=ps.get('looping', True), prewarm=ps.get('prewarm', False),
                         duration=ps.get('lengthInSec', 5), maxParticles=im.get('maxNumParticles', 100),
                         rate=curve(ps['EmissionModule'].get('rateOverTime') if ps['EmissionModule'].get('enabled') else None),
                         bursts=[{'time': b['time'], 'count': curve(b['countCurve']),
                                  'cycles': max(1, b.get('cycleCount', 1)),
                                  'interval': b.get('repeatInterval', 0), 'probability': b.get('probability', 1)}
                                 for b in ps['EmissionModule'].get('m_Bursts', [])
                                 if ps['EmissionModule'].get('enabled')],
                         lifetime=curve(im.get('startLifetime')), speed=curve(im.get('startSpeed')),
                         size=curve(im.get('startSize')),
                         sizeY=curve(im.get('startSizeY') if im.get('size3D') else im.get('startSize')),
                         startRotation=curve(im.get('startRotation')),
                         startColor=particle_gradient(im.get('startColor')),
                         gravity=curve(im.get('gravityModifier')),
                         shape={'enabled': shape.get('enabled', False), 'type': shape.get('type', 0),
                                'radius': radius, 'thickness': shape.get('radiusThickness', 1),
                                'angle': shape.get('angle', 0),
                                'scale': [shscale.get('x', 1), shscale.get('y', 1)]},
                         sizeOverLife=curve(size.get('curve')) if size.get('enabled') else None,
                         sizeYOverLife=curve(size.get('y')) if size.get('enabled') and size.get('separateAxes') else None,
                         colorOverLife=particle_gradient(color.get('gradient')) if color.get('enabled') else None,
                         rotationOverLife=curve(rot.get('curve')) if rot.get('enabled') else None,
                         uv={'enabled': uv.get('enabled', False), 'tiles': [uv.get('tilesX', 1), uv.get('tilesY', 1)],
                             'timeMode': uv.get('timeMode', 0), 'fps': uv.get('fps', 30),
                             'frame': curve(uv.get('frameOverTime')), 'start': curve(uv.get('startFrame')),
                             'cycles': uv.get('cycles', 1)},
                         velocity={'enabled': vel.get('enabled', False), 'x': curve(vel.get('x')), 'y': curve(vel.get('y'))},
                         noise=curve(noise.get('strength')) if noise.get('enabled') else None,
                         stretch=renderer.get('m_RenderMode') == 1)
        emitters.append(entry)
    if not emitters:
        raise ValueError(f'{source}：未找到可绘制发射器')
    emitters.sort(key=lambda e: e['sorting'])
    meta = next((o for o in tree.values() if '_effectDuration' in o), {})
    data = {'version': 1, 'name': name, 'duration': meta.get('_effectDuration', 5),
            'isLoop': meta.get('_isLoop', not bool(prefab)), 'emitters': emitters,
            'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest()}
    target = output / name
    target.mkdir(parents=True, exist_ok=True)
    for filename in sorted(used):
        shutil.copyfile(source.parent / filename, target / filename)
    if prefab:
        from avg_fx_mesh import convert_meshes
        if shaders is None:
            raise ValueError('--prefab 需要 --shaders 指定 shader typetree')
        convert_meshes(tree, source, data, target, shaders)
    used = {e['material']['main'] for e in emitters}
    for stale in target.glob('*.png'):
        if stale.name not in used:
            stale.unlink()
    # 禁止 NaN/Infinity，避免输出只能被部分 JSON 实现读取的描述。
    (target / 'fx.json').write_text(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    print(f'{name}: {len(emitters)} emitters, {len(used)} textures')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--prefab', help='从复合 bundle 中选择预制体并转换动画网格（需要 Pillow）')
    parser.add_argument('--shaders', type=Path, help='Shader bundle 的 TT_*.ab.json')
    args = parser.parse_args()
    if args.prefab and not args.shaders:
        parser.error('--prefab 需要 --shaders')
    try:
        shaders = next(iter(json.loads(args.shaders.read_bytes().decode('utf8', 'surrogateescape')).values())) if args.shaders else None
    except (OSError, ValueError, StopIteration) as error:
        parser.error(f'无法读取 shader typetree：{error}')
    sources = sorted(args.source.rglob('TT_*.ab.json')) if args.source.is_dir() else [args.source]
    if not sources:
        parser.error('未找到 TT_*.ab.json')
    for source in sources:
        convert(source, args.output, args.prefab, shaders)


if __name__ == '__main__':
    main()
