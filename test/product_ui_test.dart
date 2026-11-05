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

const _main = StoryEntry(
  '14-1 余火 行动前',
  'main/14-1',
  code: '14-1',
  name: '余火',
  tag: '行动前',
);
const _after = StoryEntry(
  '14-1 余火 行动后',
  'main/14-1-end',
  code: '14-1',
  name: '余火',
  tag: '行动后',
);
const _side = StoryEntry(
  'CW-1 孤星 幕间',
  'side/cw',
  code: 'CW-1',
  name: '孤星',
  tag: '幕间',
);
const _groups = [
  StoryGroup('慈悲灯塔', [_main, _after], entryType: 'MAINLINE'),
  StoryGroup('孤星', [_side], entryType: 'ACTIVITY'),
  StoryGroup('乌萨斯的孩子们', [
    StoryEntry('排练开始', 'mini/1'),
  ], entryType: 'MINI_ACTIVITY'),
  StoryGroup('一些选择', [StoryEntry('干员密录', 'memory/1')]),
];

class _MemoryCache extends FileCache {
  final data = <Uri, Uint8List>{};
  @override
  Future<void> delete(Uri uri) async {
    data.remove(uri);
  }

  @override
  Future<int> size() async =>
      data.values.fold<int>(0, (sum, bytes) => sum + bytes.length);
  @override
  Future<String?> location() async => null;
  @override
  Future<Uint8List?> read(Uri uri) async => data[uri];
  @override
  Future<void> write(Uri uri, Uint8List bytes) async {
    data[uri] = bytes;
  }
}

class _Store extends AssetStore {
  _Store() : super(cache: _MemoryCache());
  @override
  Future<List<ConnectivityResult>> cacheConnections() async => [
    ConnectivityResult.wifi,
  ];
  @override
  Stream<List<ConnectivityResult>> get cacheConnectionChanges =>
      const Stream.empty();
}

class _Repository extends StoryRepository {
  _Repository({this.groups = _groups}) : super(_Store());
  final List<StoryGroup> groups;
  int indexCalls = 0;
  int entryCalls = 0;
  int prepareCalls = 0;
  bool failIndex = false;
  bool cacheIndex = false;
  bool failCache = false;
  Completer<StoryDocument>? pending;

  @override
  Future<List<StoryGroup>> loadIndex() async {
    indexCalls++;
    if (failIndex) throw const FormatException('目录暂不可用');
    if (cacheIndex) {
      await store.writeCache(StoryRepository.indexUri, Uint8List(1048576));
    }
    return groups;
  }

  @override
  Future<StoryDocument> loadEntry(StoryEntry entry) {
    entryCalls++;
    return (pending = Completer<StoryDocument>()).future;
  }

  @override
  Future<PreparedStory> prepare(
    StoryDocument document, {
    void Function(int, int)? onProgress,
  }) async {
    prepareCalls++;
    throw StateError('本测试不应准备或下载资源');
  }

  @override
  Future<Set<String>> cachedStories() async => {};

  @override
  Future<List<String>> cacheEntry(
    StoryEntry entry, {
    CacheControl? control,
    void Function(int, int)? onProgress,
  }) async {
    entryCalls++;
    return failCache ? ['素材缺失'] : [];
  }
}

Future<_Repository> _mount(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  bool reduceMotion = false,
  bool highContrast = false,
  _Repository? repository,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final repo = repository ?? _Repository();
  addTearDown(repo.store.close);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
          highContrast: highContrast,
        ),
        child: child!,
      ),
      home: StoryLauncher(repository: repo),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets('继续观看只出现在对应剧情行，加载失败保留断点：$size', (tester) async {
      final repo = _Repository();
      final script = StoryScript.parse('上次的正文');
      final progress = PlaybackProgress(
        path: _main.path, scriptHash: PlaybackProgress.fingerprint(script),
        checkpoint: PlaybackCheckpoint(cursor: 1, trace: [0]),
      );
      await repo.store.setPlaybackProgress(progress);
      await _mount(tester, size: size, repository: repo);
      await tester.tap(find.byKey(const ValueKey('chapter-慈悲灯塔')));
      await tester.pumpAndSettle();
      final button = find.byKey(ValueKey('continue-${_main.path}'));
      expect(button, findsOneWidget);
      expect(find.text('继续观看'), findsOneWidget);
      expect(find.byKey(ValueKey('continue-${_after.path}')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(button);
      await tester.pump();
      repo.pending!.completeError(StateError('网络暂不可用'));
      await tester.pumpAndSettle();
      expect(repo.store.playbackProgress!.toJson(), progress.toJson());
      expect(button, findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      repo.pending!.complete(StoryDocument(title: _main.title, script: StoryScript.parse('更新后的正文')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('观看断点已失效'), findsOneWidget);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(repo.store.playbackProgress!.toJson(), progress.toJson());
      expect(repo.prepareCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('普通播放从头开始，不触发旧断点的恢复提示', (tester) async {
    final repo = _Repository();
    await repo.store.setPlaybackProgress(PlaybackProgress(
      path: _main.path, scriptHash: PlaybackProgress.fingerprint(StoryScript.parse('旧正文')),
      checkpoint: PlaybackCheckpoint(cursor: 1, trace: [0]),
    ));
    await _mount(tester, repository: repo);
    await tester.tap(find.byKey(const ValueKey('chapter-慈悲灯塔')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('播放 ${_main.title}'));
    await tester.pump();
    repo.pending!.complete(StoryDocument(title: _main.title, script: StoryScript.parse('新正文')));
    await tester.pumpAndSettle();
    expect(find.text('观看断点已失效'), findsNothing);
    expect(repo.prepareCalls, 1);
    expect(repo.store.playbackProgress!.path, _main.path);
  });

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets(
      '移动端毛玻璃底栏保留安全区与列表末尾空间：$size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(bottom: 24);
        addTearDown(tester.view.reset);
        final groups = [
          for (var i = 0; i < 20; i++)
            StoryGroup('测试篇章 $i', [_main], entryType: 'MAINLINE'),
        ];
        await _mount(
          tester,
          size: size,
          repository: _Repository(groups: groups),
        );
        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
        final navigation = find.byType(NavigationBar);
        final barRect = tester.getRect(navigation);
        expect(scaffold.extendBody, isTrue);
        expect(find.byType(BackdropFilter), findsOneWidget);
        expect(
          find.ancestor(
            of: find.byType(BackdropFilter),
            matching: find.byType(ClipRect),
          ),
          findsWidgets,
        );
        expect(
          tester.widget<NavigationBar>(navigation).backgroundColor!.a,
          lessThan(1),
        );
        expect(barRect.height, 96);
        final catalog = find.byKey(const PageStorageKey('mobile-chapters'));
        expect(tester.getRect(catalog).bottom, barRect.bottom);
        final scrollable = find.descendant(
          of: catalog,
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('chapter-测试篇章 19')),
          300,
          scrollable: scrollable,
        );
        tester
            .state<ScrollableState>(scrollable)
            .position
            .jumpTo(
              tester
                  .state<ScrollableState>(scrollable)
                  .position
                  .maxScrollExtent,
            );
        await tester.pumpAndSettle();
        final lastChapter = find.byKey(const ValueKey('chapter-测试篇章 19'));
        expect(
          tester.getRect(lastChapter).bottom,
          lessThanOrEqualTo(barRect.top),
        );
        await tester.tap(lastChapter);
        await tester.pumpAndSettle();
        final stages = find.byKey(const PageStorageKey('stages-测试篇章 19'));
        final stageInset = find.descendant(
          of: stages,
          matching: find.byType(SafeArea),
        );
        expect(tester.getSize(stageInset).height, barRect.height);
        await tester.tap(find.text('离线与缓存').last);
        await tester.pumpAndSettle();
        final offline = find.byKey(const PageStorageKey('offline-groups'));
        expect(tester.widget<NavigationBar>(navigation).selectedIndex, 1);
        expect(offline, findsOneWidget);
        final offlineScroll = tester.state<ScrollableState>(
          find.descendant(of: offline, matching: find.byType(Scrollable)).first,
        );
        offlineScroll.position.jumpTo(offlineScroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        final offlineInset = find.descendant(
          of: offline,
          matching: find.byType(SafeArea),
        );
        expect(offlineInset, findsOneWidget);
        expect(tester.getSize(offlineInset).height, barRect.height);
        await tester.tap(find.text('系统设置').last);
        await tester.pumpAndSettle();
        final settings = tester.widget<SingleChildScrollView>(
          find.byKey(const PageStorageKey('settings-root')),
        );
        expect(
          settings.padding!.resolve(TextDirection.ltr).bottom,
          20 + barRect.height,
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  testWidgets(
    '高对比度模式使用不透明底栏',
    (tester) async {
      await _mount(tester, highContrast: true);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).extendBody,
        isFalse,
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(
        tester
            .widget<NavigationBar>(find.byType(NavigationBar))
            .backgroundColor,
        isNull,
      );
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    '窄屏桌面端保持原有底栏',
    (tester) async {
      await _mount(tester);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).extendBody,
        isFalse,
      );
      expect(find.byType(BackdropFilter), findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    '宽屏移动端保留侧栏布局',
    (tester) async {
      await _mount(tester, size: const Size(1440, 900));
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).extendBody,
        isFalse,
      );
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
  for (final reduceMotion in [false, true]) {
    testWidgets('移动端分类点击和滑动同步，减少动画：$reduceMotion', (tester) async {
      await _mount(tester, reduceMotion: reduceMotion);
      final pages = find.byKey(const PageStorageKey('category-pages'));
      expect(pages, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('category-1')));
      await tester.pump();
      if (!reduceMotion) {
        await tester.pump(const Duration(milliseconds: 100));
        final page = tester.widget<PageView>(pages).controller!.page!;
        expect(page, greaterThan(0));
        expect(page, lessThan(1));
      }
      await tester.pumpAndSettle();
      expect(find.text('慈悲灯塔'), findsOneWidget);
      expect(find.text('孤星'), findsNothing);
      await tester.drag(pages, const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.text('孤星'), findsOneWidget);
      expect(find.text('慈悲灯塔'), findsNothing);
      await tester.drag(pages, const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.text('慈悲灯塔'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chapter-慈悲灯塔')));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.widget<PageView>(pages).controller!.page, 1);
      expect(find.text('慈悲灯塔'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({TargetPlatform.android}));
  }

  testWidgets('桌面端分类不启用滑动分页', (tester) async {
    await _mount(tester);
    expect(find.byKey(const PageStorageKey('category-pages')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('category-1')));
    await tester.pumpAndSettle();
    expect(find.text('慈悲灯塔'), findsOneWidget);
    expect(find.text('孤星'), findsNothing);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));
  for (final reduceMotion in [false, true]) {
    testWidgets('快速切换保留搜索与章节状态，减少动画：$reduceMotion', (tester) async {
      final repo = await _mount(tester, reduceMotion: reduceMotion);
      await tester.enterText(find.byKey(const Key('story-search')), '行动后');
      await tester.pumpAndSettle();
      await tester.tap(find.text('系统设置').last);
      await tester.pump();
      await tester.tap(find.text('音频通道'));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byTooltip('返回设置分类'), findsOneWidget);
      await tester.tap(find.text('离线与缓存').last);
      await tester.pump();
      await tester.tap(find.text('剧情馆').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('story-search')))
            .controller!
            .text,
        '行动后',
      );
      await tester.tap(find.byKey(const ValueKey('chapter-慈悲灯塔')));
      await tester.pump();
      expect(find.byKey(const Key('chapter-header')), findsOneWidget);
      expect(find.byKey(const ValueKey('main/14-1')), findsNothing);
      expect(find.byKey(const ValueKey('main/14-1-end')), findsOneWidget);
      await tester.tap(find.text('选择'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('系统设置').last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('返回设置分类'), findsNothing);
      expect(find.text('音频通道'), findsOneWidget);
      expect(repo.indexCalls, 1);
      expect(repo.entryCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [
    const Size(1440, 900),
    const Size(1100, 700),
    const Size(1280, 540),
    const Size(800, 600),
    const Size(390, 844),
    const Size(320, 640),
    const Size(844, 390),
  ]) {
    testWidgets('三页在 ${size.width} × ${size.height} 下无布局溢出', (tester) async {
      await _mount(tester, size: size);
      expect(tester.takeException(), isNull);
      final desktop = size.width >= 1100;
      expect(
        find.byKey(const Key('desktop-sidebar')),
        desktop ? findsOneWidget : findsNothing,
      );
      expect(find.byKey(const ValueKey('main/14-1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chapter-慈悲灯塔')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('main/14-1')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('story-search')), findsOneWidget);
      for (final label in ['离线与缓存', '系统设置', '剧情馆']) {
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }

  for (final scale in [1.0, 1.6]) {
    testWidgets('移动端滚动固定 header，选择模式可通过返回退出（文字缩放 $scale）', (tester) async {
      final entries = List.generate(
        40,
        (i) => StoryEntry(
          '剧情 $i',
          'long/$i',
          code: 'ST-$i',
          name: '长篇剧情 $i',
          tag: '行动前',
        ),
      );
      final groups = List.generate(30, (i) => StoryGroup('测试篇章 $i', entries));
      await _mount(
        tester,
        size: const Size(320, 640),
        textScale: scale,
        repository: _Repository(groups: groups),
      );
      final catalogHeader = find.byKey(const Key('catalog-header'));
      final catalogRect = tester.getRect(catalogHeader);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(tester.getRect(catalogHeader), catalogRect);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 1000));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chapter-测试篇章 0')));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      final chapterHeader = find.byKey(const Key('chapter-header'));
      final chapterRect = tester.getRect(chapterHeader);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(tester.getRect(chapterHeader), chapterRect);
      await tester.tap(find.text('选择'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('选择'), findsOneWidget);
      expect(chapterHeader, findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(catalogHeader, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('首次下载目录后刷新设置中的缓存占用', (tester) async {
    await _mount(tester, repository: _Repository()..cacheIndex = true);
    await tester.tap(find.text('系统设置').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('存储与缓存'));
    await tester.pumpAndSettle();
    expect(find.text('缓存占用：1.0 MB'), findsOneWidget);
  });

  testWidgets('分类和搜索保留真实条目，未知分类不丢失', (tester) async {
    await _mount(tester, size: const Size(1440, 900));
    await tester.tap(find.byKey(const Key('category-2')));
    await tester.pumpAndSettle();
    expect(find.text('慈悲灯塔'), findsNothing);
    expect(find.byKey(const ValueKey('side/cw')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chapter-孤星')));
    await tester.pumpAndSettle();
    expect(find.text('CW-1'), findsOneWidget);
    await tester.tap(find.byTooltip('返回剧情馆'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('category-5')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chapter-一些选择')));
    await tester.pumpAndSettle();
    expect(find.text('干员密录'), findsOneWidget);
    await tester.tap(find.byTooltip('返回剧情馆'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('category-4')));
    await tester.pumpAndSettle();
    expect(find.text('玩法衍生档案待接入'), findsOneWidget);
    await tester.tap(find.text('查看全部剧情'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('story-search')), '行动后');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('main/14-1-end')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chapter-慈悲灯塔')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('main/14-1')), findsNothing);
    expect(find.byKey(const ValueKey('main/14-1-end')), findsOneWidget);
    await tester.tap(find.byTooltip('返回剧情馆'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('story-search')), '不存在的剧情');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的剧情'), findsOneWidget);
  });

  testWidgets('移动端选择并批量缓存，显示已缓存剧情', (tester) async {
    final repo = await _mount(tester);
    await tester.tap(find.byKey(const ValueKey('chapter-慈悲灯塔')));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('全选本章').first);
    await tester.pumpAndSettle();
    expect(find.text('已选 2 幕'), findsOneWidget);
    await tester.tap(find.text('缓存'));
    await tester.pumpAndSettle();
    expect(repo.entryCalls, 2);
    expect(find.text('缓存完成，共 2 幕。'), findsOneWidget);
    expect(find.text('已离线'), findsNothing);
    expect(find.textContaining('待缓存 ('), findsNothing);
    expect(find.text(_main.title), findsNothing);
    await tester.tap(find.byKey(const ValueKey('offline-慈悲灯塔')));
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

  testWidgets('清空章节选择后仍可重试失败任务，新一轮下载回到缓存总览', (tester) async {
    final repo = await _mount(
      tester,
      repository: _Repository()..failCache = true,
    );
    await tester.tap(find.byKey(const ValueKey('chapter-慈悲灯塔')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('全选本章').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存'));
    await tester.pumpAndSettle();
    expect(repo.entryCalls, 2);
    expect(find.byTooltip('重试失败任务'), findsNWidgets(2));

    await tester.tap(find.text('剧情馆').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回剧情馆'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chapter-孤星')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('离线与缓存').last);
    await tester.pumpAndSettle();
    repo.failCache = false;
    await tester.tap(find.byTooltip('重试失败任务').first);
    await tester.pumpAndSettle();
    expect(repo.entryCalls, 4);
    expect(find.byTooltip('重试失败任务'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('offline-慈悲灯塔')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('剧情馆').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('全选本章').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存'));
    await tester.pumpAndSettle();
    expect(repo.entryCalls, 5);
    expect(find.byTooltip('返回离线与缓存'), findsNothing);
    expect(find.byKey(const ValueKey('offline-慈悲灯塔')), findsOneWidget);
    expect(find.byKey(const ValueKey('offline-孤星')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置滑块更新后切换页面保持设置值', (tester) async {
    final repo = await _mount(tester);
    await tester.tap(find.text('系统设置').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('音频通道'));
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
    expect(slider, findsNothing);
    expect(find.byTooltip('返回设置分类'), findsNothing);
    await tester.tap(find.text('音频通道'));
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
    await tester.tap(find.byKey(const ValueKey('chapter-慈悲灯塔')));
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
