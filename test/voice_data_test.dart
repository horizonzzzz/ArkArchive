import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/playback_settings.dart';
import 'package:arknights_story_player/story_player/data/voice_profile.dart';
import 'package:arknights_story_player/story_player/runtime/voice_synthesis_worker.dart';

void main() {
  test('升级时语音默认关闭，新设置保留音量与自动速度档', () {
    final legacy = PlaybackSettings.fromJson({'master': .4});
    expect(legacy.voice, 0);
    expect(legacy.speedLevel, 0);
    final saved = PlaybackSettings.fromJson(legacy.copyWith(voice: .7, speedLevel: 2).toJson());
    expect(saved.voice, .7);
    expect(saved.speedLevel, 2);
  });
  test('同名角色稳定分配中文音色，用户映射优先', () {
    final first = VoiceProfile();
    final second = VoiceProfile();
    for (final name in ['', '阿米娅', '新角色', '？', 'Doctor']) {
      expect(first.resolve(name), inInclusiveRange(3, 102));
      expect(first.resolve(name), second.resolve(name));
    }
    first.overrides['阿米娅'] = 102;
    expect(first.resolve('阿米娅'), 102);
    expect(second.resolve('阿米娅'), 3);
  });
  test('原生浮点样本编码为可播放的单声道 PCM16 WAV，并裁剪峰值', () {
    final bytes = encodeVoiceWav(Float32List.fromList([-2, 0, .5, 2]), 24000);
    final data = ByteData.sublistView(bytes);
    expect(String.fromCharCodes(bytes.take(4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    expect(data.getUint32(24, Endian.little), 24000);
    expect(data.getUint16(22, Endian.little), 1);
    expect(data.getUint32(40, Endian.little), 8);
    expect(data.getInt16(44, Endian.little), -32767);
    expect(data.getInt16(46, Endian.little), 0);
    expect(data.getInt16(50, Endian.little), 32767);
  });
}
