import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('滑动遮罩输出预乘透明度，白色半透明像素不会变成不透明白色', () async {
    final maskRecorder = ui.PictureRecorder();
    ui.Canvas(maskRecorder).drawColor(const ui.Color(0x00000000), ui.BlendMode.src);
    final maskPicture = maskRecorder.endRecording();
    final mask = await maskPicture.toImage(2, 2);
    addTearDown(mask.dispose);
    addTearDown(maskPicture.dispose);

    final program = await ui.FragmentProgram.fromAsset('assets/shaders/slide_mask.frag');
    final shader = program.fragmentShader();
    addTearDown(shader.dispose);
    final uniforms = <double>[2, 2, .5, .601, .641, .787, 0, 0, 0, 1, 1, 1, 1];
    for (var i = 0; i < uniforms.length; i++) {
      shader.setFloat(i, uniforms[i]);
    }
    shader.setImageSampler(0, mask);

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xff000000), ui.BlendMode.src);
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 2, 2), ui.Paint()..shader = shader);
    final picture = recorder.endRecording();
    addTearDown(picture.dispose);
    final image = await picture.toImage(2, 2);
    addTearDown(image.dispose);
    final bytes = (await image.toByteData())!;
    expect(bytes.getUint8(0), closeTo(128, 1));
    expect(bytes.getUint8(1), closeTo(128, 1));
    expect(bytes.getUint8(2), closeTo(128, 1));
    expect(bytes.getUint8(3), 255);
  });
}
