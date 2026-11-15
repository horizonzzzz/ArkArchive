"""仅用合成 typetree 验证转换契约；不依赖游戏资源。"""
import contextlib
import io
import json
import math
from pathlib import Path
import tempfile
import unittest

from avg_fx_extract import convert, gradient, particle_gradient, path_id
import struct
import zlib
from avg_fx_mesh import animation_tracks, evaluate, property_values, mesh_geometry, select_prefab


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

    def test_constant_particle_color_is_not_replaced_with_white_gradient(self):
        self.assertEqual(particle_gradient({'minMaxState': 0, 'maxColor': dict(r=1, g=0, b=0, a=.5)}),
                         [[0, 1, 0, 0, .5], [1, 1, 0, 0, .5]])

    def test_dense_material_track_interpolates_between_samples(self):
        clip = {'m_MuscleClip': {'m_Clip': {'data': {
            'm_StreamedClip': {'curveCount': 0, 'data': []},
            'm_DenseClip': {'m_CurveCount': 1, 'm_SampleArray': [0, 1], 'm_BeginTime': 0, 'm_SampleRate': 10},
            'm_ConstantClip': {'data': []}}}},
            'm_ClipBindingConstant': {'genericBindings': [dict(typeID=23, customType=22)]}}
        self.assertAlmostEqual(evaluate(animation_tracks(clip)[0][1], .05), .5)

    def test_mesh_binary_and_quaternion_survive_export(self):
        raw = struct.pack('<3f4B2f', 1, 2, 3, 240, 255, 255, 255, .25, .75)
        channels = [{'stream': 0, 'offset': 0, 'format': 0, 'dimension': 3},
                    {'stream': 0, 'offset': 0, 'format': 0, 'dimension': 0},
                    {'stream': 0, 'offset': 0, 'format': 0, 'dimension': 0},
                    {'stream': 0, 'offset': 12, 'format': 2, 'dimension': 4},
                    {'stream': 0, 'offset': 16, 'format': 0, 'dimension': 2}]
        mesh = {'m_VertexData': {'m_VertexCount': 1, 'm_Channels': channels,
                                'm_DataSize': raw.decode('utf8', 'surrogateescape')},
                'm_IndexBuffer': [0]*6}
        t = {'m_LocalPosition': dict(x=10, y=0, z=0), 'm_LocalScale': dict(x=2, y=2, z=2),
             'm_LocalRotation': dict(x=math.sin(math.pi/4), y=0, z=0, w=math.cos(math.pi/4))}
        result = mesh_geometry(mesh, [t])
        for actual, expected in zip(result['positions'][0], [12, -6, 4]):
            self.assertAlmostEqual(actual, expected)
        self.assertEqual(result['colors'][0], [240, 255, 255, 255])
        self.assertEqual(result['uv'][0], [.25, .75])

    def test_streamed_material_curve_and_binding_hash(self):
        raw = struct.pack('<fII4f', 0, 1, 0, 0, 0, 2, .25)
        binding = dict(path=zlib.crc32(b'child'), attribute=0x80000000 | (zlib.crc32(b'_Amount') & 0x0fffffff), typeID=23, customType=22)
        clip = {'m_MuscleClip': {'m_Clip': {'data': {
            'm_StreamedClip': {'curveCount': 1, 'data': list(struct.unpack('<%dI' % (len(raw)//4), raw))},
            'm_DenseClip': {'m_CurveCount': 0}, 'm_ConstantClip': {'data': []}}}},
            'm_ClipBindingConstant': {'genericBindings': [binding]}}
        tracks = animation_tracks(clip)
        self.assertAlmostEqual(evaluate(tracks[0][1], .1), .45)
        floats, _ = property_values({'m_SavedProperties': {'m_Floats': [['_Amount', 0]]}}, tracks, 'child', .1)
        self.assertAlmostEqual(floats['_Amount'], .45)

    def test_prefab_selection_excludes_other_scene_objects(self):
        tree = {'1': {'m_Name': 'wanted', 'm_Component': []},
                '2': {'m_Name': 'other', 'm_Component': []},
                '3': transform(1), '4': transform(2),
                '5': {'m_GameObject': ref(2), '_effectDuration': 99},
                '6': {'m_Name': 'shared_material'}}
        selected = select_prefab(tree, 'wanted')
        self.assertEqual(set(selected), {'1', '3', '6'})

if __name__ == '__main__':
    unittest.main()
