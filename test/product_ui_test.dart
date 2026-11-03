import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/app/app_theme.dart';
import 'package:arknights_story_player/app/story_launcher.dart';
import 'package:arknights_story_player/story_player/story_player.dart';

const _main = StoryEntry('14-1 余火 行动前', 'main/14-1', code: '14-1', name: '余火', tag: '行动前');
const _after = StoryEntry('14-1 余火 行动后', 'main/14-1-end', code: '14-1', name: '余火', tag: '行动后');
const _side = StoryEntry('CW-1 孤星 幕间', 'side/cw', code: 'CW-1', name: '孤星', tag: '幕间');
const _groups = [
  StoryGroup('慈悲灯塔', [_main, _after], entryType: 'MAINLINE'),
  StoryGroup('孤星', [_side], entryType: 'ACTIVITY'),
  StoryGroup('乌萨斯的孩子们', [StoryEntry('排练开始', 'mini/1')], entryType: 'MINI_ACTIVITY'),
  StoryGroup('一些选择', [StoryEntry('干员密录', 'memory/1')]),
];

class _Repository extends StoryRepository {
  _Repository() : super(AssetStore());
  int indexCalls = 0;
  int entryCalls = 0;
  int prepareCalls = 0;
  bool failIndex = false;
  Completer<StoryDocument>? pending;

  @override
  Future<List<StoryGroup>> loadIndex() async {
    indexCalls++;
    if (failIndex) throw const FormatException('目录暂不可用');
    return _groups;
  }

  @override
  Future<StoryDocument> loadEntry(StoryEntry entry) {
    entryCalls++;
    return (pending = Completer<StoryDocument>()).future;
  }

  @override
  Future<PreparedStory> prepare(StoryDocument document, {void Function(int, int)? onProgress}) async {
    prepareCalls++;
    throw StateError('本测试不应准备或下载资源');
  }
}

Future<_Repository> _mount(WidgetTester tester, {Size size = const Size(390, 844), double textScale = 1, _Repository? repository}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final repo = repository ?? _Repository();
  addTearDown(repo.store.close);
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
    home: StoryLauncher(repository: repo),
  ));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  for (final size in [const Size(1440, 900), const Size(1100, 700), const Size(1280, 540), const Size(800, 600), const Size(390, 844), const Size(320, 640), const Size(844, 390)]) {
    testWidgets('三页在 ${size.width} × ${size.height} 下无布局溢出', (tester) async {
      await _mount(tester, size: size);
      expect(tester.takeException(), isNull);
      final desktop = size.width >= 1100;
      expect(find.byKey(const Key('desktop-sidebar')), desktop ? findsOneWidget : findsNothing);
      for (final label in ['离线与缓存', '系统设置', '剧情馆']) {
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('分类和搜索保留真实条目，未知分类不丢失', (tester) async {
    await _mount(tester, size: const Size(1440, 900));
    await tester.tap(find.byKey(const Key('category-2')));
    await tester.pumpAndSettle();
    expect(find.text('慈悲灯塔'), findsNothing);
    expect(find.text('CW-1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('category-5')));
    await tester.pumpAndSettle();
    expect(find.text('干员密录'), findsOneWidget);
    await tester.tap(find.byKey(const Key('category-4')));
    await tester.pumpAndSettle();
    expect(find.text('玩法衍生档案待接入'), findsOneWidget);
    await tester.tap(find.text('查看全部剧情'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('story-search')), '行动后');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('main/14-1')), findsNothing);
    expect(find.byKey(const ValueKey('main/14-1-end')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('story-search')), '不存在的剧情');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的剧情'), findsOneWidget);
  });

  testWidgets('移动端展开、全选与缓存预览不触发网络操作', (tester) async {
    final repo = await _mount(tester);
    await tester.tap(find.text('批量管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('全选本章').first);
    await tester.pumpAndSettle();
    expect(find.text('已选 2 幕'), findsOneWidget);
    await tester.tap(find.text('缓存（预览）'));
    await tester.pumpAndSettle();
    expect(find.text('批量缓存尚未接入，本次仅预览界面。'), findsOneWidget);
    expect(repo.entryCalls, 0);
    expect(repo.prepareCalls, 0);
    await tester.tap(find.text('离线与缓存').last);
    await tester.pumpAndSettle();
    expect(find.text('待缓存 (2)'), findsOneWidget);
    expect(find.text(_main.title), findsOneWidget);
    await tester.tap(find.text('清理缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认预览'));
    await tester.pumpAndSettle();
    expect(find.text('缓存清理尚未接入，本次仅预览界面。'), findsOneWidget);
    expect(repo.prepareCalls, 0);
    await tester.tap(find.text('剧情馆').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('取消选择'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mobile-batch-bar')), findsNothing);
  });

  testWidgets('设置滑块仅更新界面，切换页面后保持本次预览值', (tester) async {
    final repo = await _mount(tester);
    await tester.tap(find.text('系统设置').last);
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('setting-主音量'));
    final before = tester.widget<Slider>(slider).value;
    await tester.tapAt(tester.getTopLeft(slider) + const Offset(45, 24));
    await tester.pumpAndSettle();
    final after = tester.widget<Slider>(slider).value;
    expect(after, isNot(before));
    await tester.tap(find.text('剧情馆').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统设置').last);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, after);
    expect(repo.indexCalls, 1);
    expect(repo.entryCalls, 0);
    expect(repo.prepareCalls, 0);
  });

  testWidgets('目录失败可重试，播放失败退出准备层并可重试', (tester) async {
    final repo = _Repository()..failIndex = true;
    await _mount(tester, repository: repo);
    expect(find.text('暂时无法读取目录'), findsOneWidget);
    repo.failIndex = false;
    await tester.tap(find.text('重新加载目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('播放 ${_main.title}'));
    await tester.pump();
    expect(find.text('正在准备演出'), findsOneWidget);
    repo.pending!.completeError(const FormatException('脚本缺失'));
    await tester.pumpAndSettle();
    expect(find.text('正在准备演出'), findsNothing);
    expect(find.textContaining('脚本缺失'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(repo.entryCalls, 2);
    repo.pending!.completeError(const FormatException('脚本缺失'));
    await tester.pumpAndSettle();
  });

  testWidgets('大字模式及搜索键盘弹出时页面仍可布局', (tester) async {
    await _mount(tester, textScale: 1.5);
    await tester.tap(find.byKey(const Key('story-search')));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(390, 440));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.tap(find.text('系统设置').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
