import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/app/app_theme.dart';
import 'package:arknights_story_player/app/story_launcher.dart';
import 'package:arknights_story_player/story_player/story_player.dart';
import 'package:arknights_story_player/story_player/data/file_cache.dart';
import 'package:arknights_story_player/story_player/data/cache_control.dart';

const _main = StoryEntry('14-1 余火 行动前', 'main/14-1', code: '14-1', name: '余火', tag: '行动前');
const _after = StoryEntry('14-1 余火 行动后', 'main/14-1-end', code: '14-1', name: '余火', tag: '行动后');
const _side = StoryEntry('CW-1 孤星 幕间', 'side/cw', code: 'CW-1', name: '孤星', tag: '幕间');
const _groups = [
  StoryGroup('慈悲灯塔', [_main, _after], entryType: 'MAINLINE'),
  StoryGroup('孤星', [_side], entryType: 'ACTIVITY'),
  StoryGroup('乌萨斯的孩子们', [StoryEntry('排练开始', 'mini/1')], entryType: 'MINI_ACTIVITY'),
  StoryGroup('一些选择', [StoryEntry('干员密录', 'memory/1')]),
];

class _MemoryCache extends FileCache {
  final data = <Uri, Uint8List>{};
  @override
  Future<void> delete(Uri uri) async { data.remove(uri); }
  @override
  Future<int> size() async => data.values.fold<int>(0, (sum, bytes) => sum + bytes.length);
  @override
  Future<String?> location() async => null;
  @override
  Future<Uint8List?> read(Uri uri) async => data[uri];
  @override
  Future<void> write(Uri uri, Uint8List bytes) async { data[uri] = bytes; }
}
class _Store extends AssetStore {
  _Store() : super(cache: _MemoryCache());
  @override
  Future<List<ConnectivityResult>> cacheConnections() async => [ConnectivityResult.wifi];
  @override
  Stream<List<ConnectivityResult>> get cacheConnectionChanges => const Stream.empty();
}
class _Repository extends StoryRepository {
  _Repository() : super(_Store());
  int indexCalls = 0;
  int entryCalls = 0;
  int prepareCalls = 0;
  bool failIndex = false;
  bool cacheIndex = false;
  Completer<StoryDocument>? pending;

  @override
  Future<List<StoryGroup>> loadIndex() async {
    indexCalls++;
    if (failIndex) throw const FormatException('目录暂不可用');
    if (cacheIndex) await store.writeCache(StoryRepository.indexUri, Uint8List(1048576));
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

  @override
  Future<Set<String>> cachedStories() async => {};

  @override
  Future<List<String>> cacheEntry(StoryEntry entry, {CacheControl? control, void Function(int, int)? onProgress}) async {
    entryCalls++;
    return [];
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

  testWidgets('首次下载目录后刷新设置中的缓存占用', (tester) async {
    await _mount(tester, repository: _Repository()..cacheIndex = true);
    await tester.tap(find.text('系统设置').last);
    await tester.pumpAndSettle();
    expect(find.text('缓存占用：1.0 MB'), findsOneWidget);
  });

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

  testWidgets('移动端选择并批量缓存，显示已缓存剧情', (tester) async {
    final repo = await _mount(tester);
    await tester.tap(find.text('批量管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('全选本章').first);
    await tester.pumpAndSettle();
    expect(find.text('已选 2 幕'), findsOneWidget);
    await tester.tap(find.text('缓存'));
    await tester.pumpAndSettle();
    expect(repo.entryCalls, 2);
    expect(find.text('缓存完成，共 2 幕。'), findsOneWidget);
    expect(find.text('待缓存 (0)'), findsOneWidget);
    await tester.tap(find.text('已离线'));
    await tester.pumpAndSettle();
    expect(find.text(_main.title), findsOneWidget);
    await tester.tap(find.byTooltip('播放 ${_main.title}'));
    await tester.pump();
    expect(repo.entryCalls, 3);
    repo.pending!.completeError(const FormatException('脚本缺失'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧情馆').last);
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
