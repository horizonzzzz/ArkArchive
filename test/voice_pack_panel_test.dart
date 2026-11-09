import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/voice_pack.dart';
import 'package:arknights_story_player/story_player/ui/voice_pack_panel.dart';
import 'package:arknights_story_player/story_player/data/playback_settings.dart';
import 'package:arknights_story_player/story_player/runtime/story_engine.dart';
import 'package:arknights_story_player/story_player/script.dart';
import 'package:arknights_story_player/story_player/ui/control_hub_sheet.dart';

class FakePackStore extends VoicePackStore {
  @override
  VoicePackStatus status = VoicePackStatus.missing;
  @override
  final profile = VoiceProfile();
  @override
  String? directory;
  @override
  String? error;
  @override
  int receivedBytes = 0;
  @override
  int installedBytes = 0;
  int installs = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> install() async { installs++; status = VoicePackStatus.downloading; notifyListeners(); }
  @override
  void pause() { status = VoicePackStatus.paused; notifyListeners(); }
  @override
  void resume() { status = VoicePackStatus.downloading; notifyListeners(); }
  @override
  void cancel() { status = VoicePackStatus.missing; notifyListeners(); }
  @override
  Future<void> remove() async { status = VoicePackStatus.missing; notifyListeners(); }
  @override
  Future<void> bind(String speaker, int? sid) async {
    if (sid == null) { profile.overrides.remove(speaker); }
    else { profile.overrides[speaker] = sid; }
    notifyListeners();
  }
}

void main() {
  testWidgets('控制中心在窄屏切换自动模式并保存速度档', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = StoryEngine(StoryScript.parse(''));
    PlaybackSettings? saved;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body:
      ControlHubSheet(engine: engine, settings: const PlaybackSettings(), onSettingsChanged: (value) => saved = value))));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('自动')); await tester.pump();
    expect(engine.autoMode, 'button_auto');
    await tester.tap(find.text('II · 标准')); await tester.pump();
    expect(saved?.speedLevel, 1);
    await tester.tap(find.text('快速')); await tester.pump();
    expect(engine.autoMode, 'quick_play');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); engine.dispose();
  });
  testWidgets('窄屏语音设置先确认下载，再提供暂停、续传和取消', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = FakePackStore();
    bool enabled = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: VoicePackPanel(packs: store, enabled: false, onEnabledChanged: (value) => enabled = value),
    ))));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(Switch)); await tester.pump();
    expect(enabled, isTrue);
    await tester.tap(find.text('下载语音包')); await tester.pumpAndSettle();
    expect(find.text('下载默认语音包'), findsOneWidget);
    expect(store.installs, 0);
    await tester.tap(find.widgetWithText(FilledButton, '下载')); await tester.pump();
    expect(store.installs, 1);
    await tester.tap(find.text('暂停')); await tester.pump();
    expect(store.status, VoicePackStatus.paused);
    await tester.tap(find.text('继续')); await tester.pump();
    expect(store.status, VoicePackStatus.downloading);
    await tester.tap(find.text('取消下载')); await tester.pumpAndSettle();
    expect(store.status, VoicePackStatus.missing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });

  testWidgets('未安装时禁用试听，音色可保存并恢复默认', (tester) async {
    final store = FakePackStore();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: VoicePackPanel(packs: store, enabled: false, onEnabledChanged: (_) {}),
    ))));
    final audition = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '试听'));
    expect(audition.onPressed, isNull);
    await store.bind('', 3); await tester.pump();
    await tester.ensureVisible(find.text('恢复默认音色'));
    await tester.tap(find.text('恢复默认音色')); await tester.pump();
    expect(store.profile.overrides.containsKey(''), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); store.dispose();
  });
}
