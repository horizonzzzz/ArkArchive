# /// script
# dependencies = ["numpy", "pillow"]
# ///
"""将太阳光晕粒子的溶解遮罩和 UV 滚动烘焙到可离线播放的贴图。"""

import json
import math
import sys
from pathlib import Path

from importlib import import_module

np = import_module('numpy')
Image = import_module('PIL.Image')

from avg_fx_mesh import ref
from avg_fx_json import dumps


DISSOLVE = -7613899480748555105
DISSOLVE_UV = -6667198903730111120
ADDITIVE = 8628681890072029720


def bake(source, target):
    tree_path = source / 'TT_avg_072_speech.ab.json'
    try:
        tree = next(iter(json.loads(tree_path.read_text(encoding='utf8')).values()))
        data_path = target / 'fx.json'
        data = json.loads(data_path.read_text(encoding='utf8'))
    except (OSError, UnicodeError, ValueError, StopIteration) as error:
        raise ValueError(f'无法读取太阳光晕源文件或目标文件：{error}') from error

    renderers = {
        tree[ref(obj['m_GameObject'])]['m_Name']: obj
        for obj in tree.values()
        if 'm_Materials' in obj and ref(obj.get('m_GameObject')) in tree
    }
    generated = {}
    for entry in data['emitters']:
        renderer = renderers[entry['name']]
        material = tree[ref(renderer['m_Materials'][0])]
        shader = material['m_Shader']['m_PathID']
        if shader not in (DISSOLVE, DISSOLVE_UV, ADDITIVE):
            raise ValueError(f"不支持太阳光晕材质：{material['m_Name']} ({shader})")
        entry['material']['colorMultiplier'] = 2
        if shader == ADDITIVE:
            continue

        name = material['m_Name']
        if name not in generated:
            props = material['m_SavedProperties']
            envs = dict(props['m_TexEnvs'])
            floats = dict(props['m_Floats'])
            colors = dict(props['m_Colors'])
            main_env, mask_env = envs['_MainTex'], envs['_DissolveTex']

            def texture(env):
                obj = tree[ref(env['m_Texture'])]
                return np.asarray(Image.open(source / (obj['m_Name'] + '.png')).convert('RGBA'))

            main, mask = texture(main_env), texture(mask_env)
            width = height = 128
            y, x = np.mgrid[0:height, 0:width]
            u, v = (x + .5) / width, 1 - (y + .5) / height

            def sample(image, env, offset_x=0, offset_y=0):
                scale, offset = env['m_Scale'], env['m_Offset']
                uu = np.mod(u * scale['x'] + offset['x'] + offset_x, 1)
                vv = np.mod(v * scale['y'] + offset['y'] + offset_y, 1)
                ix = np.floor(uu * image.shape[1]).astype(int) % image.shape[1]
                iy = np.floor(np.mod(1 - vv, 1) * image.shape[0]).astype(int) % image.shape[0]
                return image[iy, ix]

            uv = colors.get('_UVTween', {}) if shader == DISSOLVE_UV else {}
            fps, duration = 15, 10 if uv else 0
            count = math.ceil(duration * fps) + 1
            columns = 8 if duration else 1
            atlas = Image.new('RGBA', (width * columns, height * math.ceil(count / columns)))
            amount, border = floats['_Amount'], max(floats['_BorderWidth'], 1e-6)
            for frame in range(count):
                time = frame / fps
                color = sample(main, main_env, uv.get('r', 0) * time, uv.get('g', 0) * time).copy()
                dissolve = sample(mask, mask_env, uv.get('b', 0) * time, uv.get('a', 0) * time)[:, :, 0] / 255
                alpha = np.clip((dissolve - amount + border * (1 - round(amount + .5))) / border, 0, 1)
                color[:, :, 3] = np.rint(color[:, :, 3] * alpha).astype(np.uint8)
                atlas.paste(Image.fromarray(color), ((frame % columns) * width, (frame // columns) * height))
            filename = 'baked_' + name + '.png'
            atlas.save(target / filename)
            frames = dict(count=count, columns=columns, fps=fps, width=width, height=height) if duration else None
            generated[name] = filename, frames
        filename, frames = generated[name]
        entry['material']['main'] = filename
        if frames is not None:
            entry['material']['frames'] = frames
    data_path.write_text(dumps(data), encoding='utf8')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('用法: uv run tool/avg_fx_solar_bake.py <已归一化源目录> <已转换目标目录>')
    bake(Path(sys.argv[1]), Path(sys.argv[2]))
