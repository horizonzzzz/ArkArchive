"""把 AVG_072_speech 的 Animator 变换与颜色采样写入已转换的粒子描述。"""

import json
import math
import struct
import sys
import zlib
from pathlib import Path

from avg_fx_mesh import evaluate, ref
from avg_fx_json import dumps


def convert(source, target):
    try:
        tree = next(iter(json.loads(source.read_bytes().decode('utf8', 'surrogateescape')).values()))
        data = json.loads(target.read_text(encoding='utf8'))
    except (OSError, UnicodeError, ValueError, StopIteration) as error:
        raise ValueError(f'无法读取特效源文件或目标文件：{error}') from error
    transforms = {ref(o.get('m_GameObject')): o for o in tree.values() if 'm_LocalPosition' in o}
    renderers = {ref(o.get('m_GameObject')): o for o in tree.values() if 'm_Materials' in o}

    def path(go):
        names = []
        while go in transforms:
            names.append(tree[go]['m_Name'])
            go = ref(tree.get(ref(transforms[go].get('m_Father')), {}).get('m_GameObject'))
        return '/'.join(reversed(names[:-1]))

    clips = [o for o in tree.values() if o.get('m_Name') == 'AVG_072_speech' and 'm_MuscleClip' in o]
    if len(clips) != 1:
        raise ValueError('太阳光晕需要唯一的 AVG_072_speech 动画')
    clip = clips[0]
    packed = clip['m_MuscleClip']['m_Clip']['data']
    stream = packed['m_StreamedClip']
    if packed['m_DenseClip']['m_CurveCount']:
        raise ValueError('太阳光晕动画包含尚未支持的 dense 轨道')
    raw = struct.pack(f"<{len(stream['data'])}I", *stream['data'])
    tracks = [[] for _ in range(stream['curveCount'])]
    offset = 0
    while offset < len(raw):
        time, count = struct.unpack_from('<fI', raw, offset)
        offset += 8
        for _ in range(count):
            index, *values = struct.unpack_from('<I4f', raw, offset)
            offset += 20
            if math.isfinite(time):
                tracks[index].append((time, values))
    tracks.extend([[(0, [0, 0, 0, value])] for value in packed['m_ConstantClip']['data']])
    bindings, index = {}, 0
    for binding in clip['m_ClipBindingConstant']['genericBindings']:
        width = 3 if binding['typeID'] == 4 else 1
        key = (binding['path'], binding['typeID'], binding['attribute'])
        bindings[key] = tracks[index:index + width]
        index += width
    if index != len(tracks):
        raise ValueError('太阳光晕动画轨道数量不符')

    paths = {go: zlib.crc32(path(go).encode()) for go in transforms}
    tint_hash = zlib.crc32(b'_TintColor') & 0x0fffffff
    by_name = {tree[go]['m_Name']: go for go in renderers if go in transforms}
    fps = 30
    duration = clip['m_MuscleClip']['m_StopTime']
    for entry in data['emitters']:
        go = by_name[entry['name']]
        chain, current = [], go
        while current in transforms:
            chain.append(current)
            current = ref(tree.get(ref(transforms[current].get('m_Father')), {}).get('m_GameObject'))
        chain = chain[:-1]
        renderer = renderers[go]
        frames = []
        for step in range(round(duration * fps) + 1):
            time = step / fps
            points = [[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]]
            for node in chain:
                t = transforms[node]
                p = [t['m_LocalPosition'][c] for c in 'xyz']
                s = [t['m_LocalScale'][c] for c in 'xyz']
                q = t['m_LocalRotation']
                angle = math.atan2(2 * (q['w'] * q['z'] + q['x'] * q['y']),
                                   1 - 2 * (q['y'] ** 2 + q['z'] ** 2))
                for attribute, values in ((1, p), (3, s)):
                    track = bindings.get((paths[node], 4, attribute))
                    if track:
                        values[:] = [evaluate(axis, time) for axis in track]
                rotation = bindings.get((paths[node], 4, 4))
                if rotation:
                    angle = math.radians(evaluate(rotation[2], time))
                # 单轴粒子使用 X 缩放生成摄像机平面上的方形，不能将 Y=0 当作不可见。
                sy = s[1] if s[1] else s[2]
                cos, sin = math.cos(angle), math.sin(angle)
                points = [[p[0] + x * s[0] * cos - y * sy * sin,
                           p[1] + x * s[0] * sin + y * sy * cos] for x, y in points]
            origin, xaxis, yaxis = points
            tint = list(entry['material']['tint'])
            for channel in range(4):
                track = bindings.get((paths[go], 199, ((channel + 4) << 28) | tint_hash))
                if track:
                    tint[channel] = evaluate(track[0], time)
            active = [v for (p, kind, _), v in bindings.items() if p == paths[go] and kind == 1]
            if active and evaluate(active[0][0], time) < .5:
                tint[3] = 0
            frame = [*origin, 0, (xaxis[0] - origin[0]),
                     (xaxis[1] - origin[1]), 0,
                     (yaxis[0] - origin[0]),
                     (yaxis[1] - origin[1]), 0, *tint]
            frames.append([round(float(value), 6) for value in frame])
        entry.update(position=[0, 0], scale=[1, 1], rotation=0,
                     alignment=renderer.get('m_RenderAlignment', 0),
                     pivot=[renderer.get('m_Pivot', {}).get(c, 0) for c in 'xy'],
                     lengthScale=renderer.get('m_LengthScale', 1),
                     animation={'fps': fps, 'frames': frames})
        # 这些粒子使用 Additive / Dissolve Add，材质保存的 Standard 混合字段并非 shader 的混合模式。
        entry['material'].update(srcBlend=5, dstBlend=1)
    data['drawAfterImages'] = True
    target.write_text(dumps(data), encoding='utf8')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('用法: uv run python tool/avg_fx_solar_animation.py <原始 typetree.json> <转换后的 fx.json>')
    convert(Path(sys.argv[1]), Path(sys.argv[2]))
