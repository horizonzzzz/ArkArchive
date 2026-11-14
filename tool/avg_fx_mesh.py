"""复合预制体的网格与材质动画转换；运行时只需播放图集和投影网格。"""

import math
import struct
import zlib


def ref(value):
    return str((value or {}).get('m_PathID', 0)) if not (value or {}).get('m_FileID') else ''


def select_prefab(tree, name):
    roots = [k for k, o in tree.items() if o.get('m_Name') == name and 'm_Component' in o]
    if len(roots) != 1:
        raise ValueError(f'需要唯一预制体：{name}，找到 {len(roots)} 个')
    transforms = {ref(o.get('m_GameObject')): o for o in tree.values() if 'm_LocalPosition' in o}
    def inside(go):
        visited = set()
        while go in transforms:
            if go in visited:
                raise ValueError('Transform 父子关系存在循环')
            visited.add(go)
            if go == roots[0]:
                return True
            go = ref(tree.get(ref(transforms[go].get('m_Father')), {}).get('m_GameObject'))
        return False
    return {k: o for k, o in tree.items()
            if inside(k) or inside(ref(o.get('m_GameObject')))
            or ('m_Component' not in o and 'm_GameObject' not in o)}


def animation_tracks(clip):
    """读取 Unity streamed 三次多项式、dense 和 constant 数值轨道。"""
    packed = clip['m_MuscleClip']['m_Clip']['data']
    streamed = packed['m_StreamedClip']
    words = streamed['data']
    raw = struct.pack(f'<{len(words)}I', *words)
    tracks = [[] for _ in range(streamed['curveCount'])]
    offset = 0
    while offset < len(raw):
        time, count = struct.unpack_from('<fI', raw, offset)
        offset += 8
        for _ in range(count):
            index, *coefficients = struct.unpack_from('<I4f', raw, offset)
            offset += 20
            if math.isfinite(time):
                tracks[index].append((time, coefficients))
    dense = packed['m_DenseClip']
    for index in range(dense['m_CurveCount']):
        samples = dense['m_SampleArray'][index::dense['m_CurveCount']]
        rate = dense['m_SampleRate']
        tracks.append([(dense['m_BeginTime'] + i / rate,
                        [0, 0, (samples[min(i+1, len(samples)-1)]-v)*rate, v])
                       for i, v in enumerate(samples)])
    for value in packed['m_ConstantClip']['data']:
        tracks.append([(0, [0, 0, 0, value])])
    bindings = clip['m_ClipBindingConstant']['genericBindings']
    if len(tracks) != len(bindings) or any(b['typeID'] != 23 or b['customType'] != 22 for b in bindings):
        raise ValueError('当前转换器只支持 renderer 材质数值轨道，不能静默丢弃其他动画')
    return list(zip(bindings, tracks))


def evaluate(track, time):
    key = track[0] if track else (0, [0, 0, 0, 0])
    for candidate in track:
        if candidate[0] > time:
            break
        key = candidate
    a, b, c, d = key[1]
    dt = max(0, time - key[0])
    return ((a * dt + b) * dt + c) * dt + d


def property_values(material, tracks, path, time):
    props = material['m_SavedProperties']
    values = {str(k): float(v) for k, v in props.get('m_Floats', [])}
    vectors = {k: [v[c] for c in 'rgba'] for k, v in props.get('m_Colors', [])}
    for key, value in props.get('m_TexEnvs', []):
        vectors[key + '_ST'] = [value['m_Scale']['x'], value['m_Scale']['y'],
                                value['m_Offset']['x'], value['m_Offset']['y']]
    crc = lambda s: zlib.crc32(s.encode()) & 0x0fffffff
    path_hash = zlib.crc32(path.encode())
    for binding, track in tracks:
        if binding['path'] != path_hash:
            continue
        attribute = binding['attribute']
        kind, hashed = attribute >> 28, attribute & 0x0fffffff
        if kind == 8:
            keys = [key for key in values if crc(key) == hashed]
            if len(keys) != 1:
                raise ValueError(f'无法解析材质属性 {path}: {attribute}')
            values[keys[0]] = evaluate(track, time)
        else:
            keys = [key for key in vectors if crc(key) == hashed]
            if len(keys) != 1 or kind > 7:
                raise ValueError(f'无法解析材质向量 {path}: {attribute}')
            vectors[keys[0]][kind % 4] = evaluate(track, time)
    return values, vectors


def rotate(point, quaternion):
    x, y, z = point
    qx, qy, qz, qw = [quaternion[k] for k in 'xyzw']
    tx, ty, tz = 2 * (qy*z-qz*y), 2 * (qz*x-qx*z), 2 * (qx*y-qy*x)
    return [x + qw*tx + qy*tz-qz*ty, y + qw*ty + qz*tx-qx*tz, z + qw*tz + qx*ty-qy*tx]


def transform_point(point, hierarchy):
    for transform in hierarchy:
        point = rotate([point[j] * transform['m_LocalScale']['xyz'[j]] for j in range(3)], transform['m_LocalRotation'])
        point = [point[j] + transform['m_LocalPosition']['xyz'[j]] for j in range(3)]
    return point


def mesh_geometry(mesh, hierarchy):
    vertex = mesh['m_VertexData']
    channels = vertex['m_Channels']
    if any(c['stream'] != 0 for c in channels if c['dimension']):
        raise ValueError('暂不支持多 stream 顶点缓冲区')
    sizes = {0: 4, 1: 2, 2: 1, 3: 1, 4: 1, 5: 1, 6: 2, 7: 2, 8: 4, 9: 4, 10: 4, 11: 4}
    stride = max(c['offset'] + sizes[c['format']] * c['dimension'] for c in channels if c['dimension'])
    data = vertex['m_DataSize']
    raw = data.encode('utf8', 'surrogateescape') if isinstance(data, str) else bytes(data)
    if len(raw) != stride * vertex['m_VertexCount']:
        raise ValueError('顶点缓冲区长度不符；检查解包时是否丢失了二进制字节')
    position, color, uv = channels[0], channels[3], channels[4]
    if position['format'] != 0 or uv['format'] != 0:
        raise ValueError('当前只支持 float32 位置和 UV')
    positions, uvs, colors = [], [], []
    for i in range(vertex['m_VertexCount']):
        point = list(struct.unpack_from('<3f', raw, i * stride + position['offset']))
        point = transform_point(point, hierarchy)
        positions.append(point)
        uvs.append(list(struct.unpack_from('<2f', raw, i * stride + uv['offset'])))
        colors.append(list(raw[i * stride + color['offset']:i * stride + color['offset'] + 4]) if color['dimension'] else [255]*4)
    indices = bytes(mesh['m_IndexBuffer'])
    fmt = 'I' if mesh.get('m_IndexFormat') == 1 else 'H'
    indices = list(struct.unpack(f'<{len(indices) // struct.calcsize(fmt)}{fmt}', indices))
    if len(indices) % 3 or any(i >= len(positions) for i in indices):
        raise ValueError('网格三角形索引无效')
    return dict(positions=positions, uv=uvs, colors=colors, indices=indices)


def bake_material(material, shader, tracks, path, tree, source, target, filename, duration):
    from importlib import import_module
    Image = import_module('PIL.Image')
    shader_name = shader['m_ParsedForm']['m_Name']
    supported = {'Torappu/Particles/Dissolve/Dissolve Add', 'Torappu/Particles/Dissolve/Dissolve AB', 'Torappu/Particles/Additive'}
    if shader_name not in supported:
        raise ValueError(f'尚未实现材质转换：{shader_name}')
    props = dict(material['m_SavedProperties']['m_TexEnvs'])
    def texture(name):
        tex = tree[ref(props[name]['m_Texture'])]
        return Image.open(source.parent / (tex['m_Name'] + '.png')).convert('RGBA')
    main = texture('_MainTex')
    dissolve = texture('_DissolveTex') if '_DissolveTex' in props else None
    fps, columns = 30, 8 if duration > 0 else 1
    count = math.ceil(duration * fps) + 1
    width, height = min(512, main.width), min(128, main.height)
    atlas = Image.new('RGBA', (width * columns, height * math.ceil(count / columns)))
    def sample(image, u, v):
        # Unity UV 原点在左下；ArkUnpacker PNG 原点在左上。
        return image.getpixel((int((u % 1) * image.width) % image.width,
                               int(((1-v) % 1) * image.height) % image.height))
    for frame in range(count):
        floats, vectors = property_values(material, tracks, path, frame / fps)
        tint = vectors.get('_TintColor', [1]*4)
        main_st = vectors.get('_MainTex_ST', [1, 1, 0, 0])
        mask_st = vectors.get('_DissolveTex_ST', [1, 1, 0, 0])
        amount, border = floats.get('_Amount', 0), max(1e-6, floats.get('_BorderWidth', 0.01))
        pixels = []
        for y in range(height):
            for x in range(width):
                u, v = (x + .5) / width, 1 - (y + .5) / height
                color = sample(main, u*main_st[0]+main_st[2], v*main_st[1]+main_st[3])
                channel = round(floats.get('_MainTexChannel', 0))
                if channel:
                    component = {1: 0, 2: 1, 3: 2}.get(channel)
                    if component is None:
                        raise ValueError(f'不支持的 MainTexChannel：{channel}')
                    color = (color[component],) * 4
                alpha = 1
                if dissolve:
                    mask = sample(dissolve, u*mask_st[0]+mask_st[2], v*mask_st[1]+mask_st[3])[0] / 255
                    # 原版 GLSL：clamp((mask-amount+border*(1-roundEven(amount+.5)))/border,0,1)。
                    alpha = max(0, min(1, (mask-amount+border*(1-round(amount+.5))) / border))
                pixels.append(tuple(round(max(0, min(255, color[c] * 2 * tint[c] * (alpha if c == 3 else 1)))) for c in range(4)))
        tile = Image.new('RGBA', (width, height))
        tile.putdata(pixels)
        atlas.paste(tile, ((frame % columns)*width, (frame // columns)*height))
    atlas.save(target / filename)
    state = shader['m_ParsedForm']['m_SubShaders'][0]['m_Passes'][0]['m_State']['rtBlend0']
    return dict(main=filename, tint=[1]*4, mainColor=[1]*4, uvScroll=[0, 0],
                srcBlend=state['srcBlend']['val'], dstBlend=state['destBlend']['val'],
                frames=dict(count=count, columns=columns, fps=fps, width=width, height=height))


def convert_meshes(tree, source, data, target, shaders):
    transforms = {ref(o.get('m_GameObject')): o for o in tree.values() if 'm_LocalPosition' in o}
    filters = {ref(o.get('m_GameObject')): o for o in tree.values() if 'm_Mesh' in o and 'm_GameObject' in o and 'm_Materials' not in o}
    clips = [o for o in tree.values() if o.get('m_Name', '').lower() == data['name'] and 'm_MuscleClip' in o]
    tracks = animation_tracks(clips[0]) if clips else []
    def hierarchy(go):
        result = []
        while go in transforms:
            transform = transforms[go]
            result.append(transform)
            go = ref(tree.get(ref(transform.get('m_Father')), {}).get('m_GameObject'))
        return result
    for renderer in tree.values():
        go = ref(renderer.get('m_GameObject'))
        if go not in transforms or not renderer.get('m_Materials') or go in filters:
            continue
        entries = [e for e in data['emitters'] if e['name'] == tree[go]['m_Name'] and e['kind'] == 'particle']
        if not entries:
            continue
        entry = entries[0]
        chain = hierarchy(go)[:-1]
        origin = transform_point([0, 0, 0], chain)
        basis = [[v-origin[j] for j, v in enumerate(transform_point(p, chain))]
                 for p in ([1, 0, 0], [0, 1, 0])]
        entry.update(position=[0, 0], scale=[1, 1], rotation=0,
                     transform3D=[origin, *basis], alignment=renderer.get('m_RenderAlignment', 0),
                     pivot=[renderer.get('m_Pivot', {}).get(c, 0) for c in 'xy'],
                     lengthScale=renderer.get('m_LengthScale', 1))
        material = tree[ref(renderer['m_Materials'][0])]
        shader = shaders[str(material['m_Shader']['m_PathID'])]
        entry['material'] = bake_material(material, shader, [], '', tree, source, target,
                                          f'particle_{go.replace("-", "n")}.png', 0)
    for renderer in tree.values():
        go = ref(renderer.get('m_GameObject'))
        if go not in filters or not renderer.get('m_Materials'):
            continue
        name = tree[go]['m_Name']
        entries = [e for e in data['emitters'] if e['name'] == name and e['kind'] == 'mesh']
        if len(entries) != 1 or len(renderer['m_Materials']) != 1:
            raise ValueError(f'网格名称或材质不唯一：{name}')
        entry = entries[0]
        mesh = tree[ref(filters[go]['m_Mesh'])]
        chain = hierarchy(go)
        path = '/'.join(tree[ref(t['m_GameObject'])]['m_Name'] for t in reversed(chain[:-1]))
        material = tree[ref(renderer['m_Materials'][0])]
        shader = shaders[str(material['m_Shader']['m_PathID'])]
        entry['geometry'] = mesh_geometry(mesh, chain[:-1])
        entry['material'] = bake_material(material, shader, tracks, path, tree, source, target,
                                           f'mesh_{len([e for e in data["emitters"] if "geometry" in e])}.png', data['duration'])
