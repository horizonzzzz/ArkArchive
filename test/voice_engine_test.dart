import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/script.dart';
import 'package:arknights_story_player/story_player/runtime/story_engine.dart';
import 'package:arknights_story_player/story_player/runtime/dialogue_voice.dart';

class FakeVoice implements DialogueVoice {
  @override
  final ValueNotifier<VoiceStatus> status = ValueNotifier(VoiceStatus.idle);
  final spoken = <({String speaker, String text})>[];
  Completer<void>? pending;
  int stops = 0;
  bool paused = false;
  bool fail = false;
  void complete() { final old = pending; pending = null; old?.complete(); }
  @override
  Future<void> speak({required String speaker, required String text, int? requestId}) {
    spoken.add((speaker: speaker, text: text));
    if (fail) return Future.error(StateError('模拟合成失败'));
    return (pending = Completer<void>()).future;
  }
  @override
  Future<void> stop() async { stops++; complete(); }
  @override
  Future<void> pause() async { paused = true; }
  @override
  Future<void> resume() async { paused = false; }
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async { await stop(); status.dispose(); }
}

void main() {
  testWidgets('点击补全对白不会打断语音，切句才打断', (tester) async {
    final voice = FakeVoice();
    final engine = StoryEngine(StoryScript.parse('[name="阿米娅"]<b>第一句话</b>\n[name="博士"]第二句'), voice: voice);
    await engine.start();
    expect(voice.spoken.single, (speaker: '阿米娅', text: '第一句话'));
    final stops = voice.stops;
    await engine.advance();
    expect(voice.stops, stops);
    expect(engine.typing, isFalse);
    await engine.advance();
    expect(voice.spoken.last.speaker, '博士');
    expect(voice.stops, greaterThan(stops));
    engine.dispose();
    await tester.pump();
  });

  testWidgets('自动播放等待语音结束，迟到的旧完成不会放行新句', (tester) async {
    final initial = tester.binding.clock.now();
    final voice = FakeVoice();
    final engine = StoryEngine(StoryScript.parse('[name="甲"]甲\n[name="乙"]乙\n[name="丙"]丙'),
      voice: voice, autoWaitSeconds: 1, elapsed: () => tester.binding.clock.now().difference(initial));
    engine.setAutoPlay(true);
    await engine.start();
    await tester.pump(const Duration(seconds: 4));
    expect(engine.state.speaker, '甲');
    final old = voice.pending!;
    old.complete(); voice.pending = null;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(engine.state.speaker, '乙');
    await tester.pump(const Duration(seconds: 4));
    expect(engine.state.speaker, '乙');
    voice.complete();
    await tester.pump(); await tester.pump(const Duration(milliseconds: 32));
    expect(engine.state.speaker, '丙');
    engine.dispose(); await tester.pump();
  });

  testWidgets('快速播放静音，退出快速播放后朗读当前句', (tester) async {
    final voice = FakeVoice();
    final engine = StoryEngine(StoryScript.parse('[name="甲"]第一句\n[name="乙"]第二句'), voice: voice);
    await engine.start();
    final count = voice.spoken.length;
    engine.setFastForward(4);
    expect(voice.pending, isNull);
    await engine.advance(); await engine.advance();
    expect(voice.spoken.length, count);
    engine.setFastForward(0);
    expect(voice.spoken.last.speaker, '乙');
    engine.setAutoMode('quick_play');
    expect(voice.pending, isNull);
    engine.dispose(); await tester.pump();
  });

  testWidgets('暂停与恢复同时控制语音，重启停止旧句', (tester) async {
    final voice = FakeVoice();
    final engine = StoryEngine(StoryScript.parse('[name="甲"]第一句'), voice: voice);
    await engine.start();
    await engine.setPaused(true); expect(voice.paused, isTrue);
    await engine.setPaused(false); expect(voice.paused, isFalse);
    final before = voice.stops;
    await engine.restart();
    expect(voice.stops, greaterThan(before));
    engine.dispose(); await tester.pump();
  });

  testWidgets('合成失败不阻止自动播放', (tester) async {
    final initial = tester.binding.clock.now();
    final voice = FakeVoice()..fail = true;
    final engine = StoryEngine(StoryScript.parse('[name="甲"]甲\n[name="乙"]乙'), voice: voice,
      autoWaitSeconds: 1, elapsed: () => tester.binding.clock.now().difference(initial));
    engine.setAutoPlay(true);
    await engine.start(); await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(engine.state.speaker, '乙');
    expect(engine.warnings.any((message) => message.contains('模拟合成失败')), isTrue);
    engine.dispose(); await tester.pump();
  });
}
