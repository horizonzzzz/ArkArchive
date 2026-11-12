"""仅用合成 typetree 验证转换契约；不依赖游戏资源。"""
import contextlib
import io
import json
import math
from pathlib import Path
import tempfile
import unittest

from avg_fx_extract import convert, gradient, path_id


def ref(pid, file=0):
    return {'m_PathID': pid, 'm_FileID': file}


def transform(go, parent=0, position=(0, 0), scale=(1, 1), angle=0.0):
    return {'m_GameObject': ref(go), 'm_Father': ref(parent),
            'm_LocalPosition': dict(x=position[0], y=position[1]),
            'm_LocalScale': dict(x=scale[0], y=scale[1]),
            'm_LocalRotation': dict(x=0, y=0, z=math.sin(angle/2), w=math.cos(angle/2))}


class ExtractTest(unittest.TestCase):
    def test_independent_renderer_transform_and_size(self):
        ps = {'m_GameObject': ref(2), 'InitialModule': {
            'startSize': {'scalar': 2}, 'startSizeY': {'scalar': .1}, 'size3D': False},
            **{key: {} for key in ('ShapeModule', 'UVModule', 'SizeModule', 'ColorModule',
                                  'RotationModule', 'VelocityModule', 'NoiseModule', 'EmissionModule')}}
        tree = {'1': {'m_Name': 'root'}, '2': {'m_Name': 'fire'},
                '3': transform(1, scale=(2, 2), angle=math.pi/2),
                '4': transform(2, parent=3, position=(10, 0)), '5': ps,
                '6': {'m_GameObject': ref(2), 'm_Materials': [ref(7)]},
                '7': {'m_SavedProperties': {'m_TexEnvs': [['_MainTex', {'m_Texture': ref(8)}]]}},
                '8': {'m_Name': 'synthetic'}, '9': {'_effectDuration': 2, '_isLoop': True}}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'TT_test_fx.ab.json'
            source.write_text(json.dumps({'asset': tree}), encoding='utf-8')
            (root / 'synthetic.png').write_bytes(b'fixture-only')
            with contextlib.redirect_stdout(io.StringIO()):
                result = convert(source, root / 'out')
            e = result['emitters'][0]
            self.assertEqual(e['kind'], 'particle')
            self.assertAlmostEqual(e['position'][0], 0)
            self.assertAlmostEqual(e['position'][1], 20)
            self.assertEqual(e['sizeY'], e['size'])
            self.assertEqual(e['scale'], [2, 2])
            self.assertEqual((root / 'out/test_fx/synthetic.png').read_bytes(), b'fixture-only')
            self.assertEqual(len(result['sourceSha256']), 64)
            (root / 'synthetic.png').unlink()
            with self.assertRaises(FileNotFoundError), contextlib.redirect_stdout(io.StringIO()):
                convert(source, root / 'other')

    def test_external_reference_does_not_resolve_local_id(self):
        self.assertEqual(path_id(ref(12, file=1)), '')
        self.assertEqual(path_id(ref(12)), '12')

    def test_gradient_combines_alpha_and_color_timeline(self):
        stops = gradient({'m_NumColorKeys': 2, 'm_NumAlphaKeys': 2,
                          'ctime0': 0, 'ctime1': 65535, 'atime0': 0, 'atime1': 32768,
                          'key0': dict(r=1, g=0, b=0, a=0),
                          'key1': dict(r=0, g=1, b=0, a=1)})
        self.assertEqual(len(stops), 3)
        self.assertAlmostEqual(stops[1][1], .5, places=4)
        self.assertEqual(stops[1][4], 1)
        self.assertEqual(stops[-1], [1, 0, 1, 0, 1])


if __name__ == '__main__':
    unittest.main()
