import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:arknights_story_player/app/settings_page.dart';
import 'package:arknights_story_player/app/app_theme.dart';
import 'package:arknights_story_player/app/cache_job.dart';
import 'package:arknights_story_player/app/cache_page.dart';
import 'package:arknights_story_player/app/story_launcher.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/data/cache_control.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/data/story_repository.dart';
import 'package:arknights_story_player/story_player/script.dart';

import 'data_test.dart' show MemoryCache;

class DesktopStore extends AssetStore {
  DesktopStore() : super(cache: MemoryCache());
  @override
  bool get isMobile => false;
}

class MobileStore extends AssetStore {
  MobileStore() : super(cache: MemoryCache());
  List<ConnectivityResult> connections = [ConnectivityResult.mobile];
  final changes = StreamController<List<ConnectivityResult>>.broadcast(
    sync: true,
  );
  @override
  bool get isMobile => true;
  @override
  Future<List<ConnectivityResult>> cacheConnections() async => connections;
  @override
  Stream<List<ConnectivityResult>> get cacheConnectionChanges => changes.stream;
  @override
  void close() {
    changes.close();
    super.close();
  }
}

class QueueRepository extends StoryRepository {
  QueueRepository(super.store);
  final entries = List.generate(6, (i) => StoryEntry('剧情 $i', 'test/$i'));
  final started = <String>[];
  final releases = <String, Completer<void>>{};
  final offline = <String>{};
  @override
  Future<List<StoryGroup>> loadIndex() async => [StoryGroup('测试章节', entries)];
  @override
  Future<Set<String>> cachedStories() async => offline.toSet();
  @override
  Future<List<String>> cacheEntry(
    StoryEntry entry, {
    CacheControl? control,
    void Function(int, int)? onProgress,
  }) async {
    started.add(entry.path);
    onProgress?.call(1, 2);
    await (releases[entry.path] = Completer<void>()).future;
    await control?.checkpoint();
    offline.add(entry.path);
    return [];
  }

  @override
  Future<void> forgetCachedStory(StoryEntry entry) async {
    offline.remove(entry.path);
  }

  @override
  Future<void> deleteCachedStory(StoryEntry entry) async {
    offline.remove(entry.path);
  }
}

/// 在队列仓库上额外支持播放准备，用于验证下载中播放已缓存剧情。
class PlayQueueRepository extends QueueRepository {
  PlayQueueRepository(super.store);
  final loaded = <String>[];

  @override
  Future<StoryDocument> loadEntry(StoryEntry entry) async {
    loaded.add(entry.path);
    return StoryDocument(
      title: entry.title,
      script: StoryScript.parse('[name="甲"]对白'),
    );
  }

  @override
  Future<PreparedStory> prepare(
    StoryDocument document, {
    void Function(int, int)? onProgress,
  }) async {
    return PreparedStory(
      document,
      MediaCatalog(variables: {}, characters: {}, backgroundPpu: {}),
      store,
      const [],
    );
  }
}

CachePage page({
  List<StoryEntry> cached = const [],
  Map<String, CacheJob> jobs = const {},
  bool caching = false,
  ValueChanged<List<StoryEntry>>? onDelete,
}) => CachePage(
  cached: cached,
  jobs: jobs,
  caching: caching,
  deleting: false,
  done: 0,
  total: jobs.isEmpty ? 1 : jobs.length,
  onBrowse: () {},
  onRetry: (_) {},
  onOpen: (_) {},
  onToggleJob: (_) {},
  onRemoveJob: (_) {},
  onDeleteCached: onDelete ?? (_) {},
);

Future<void> startQueue(WidgetTester tester, QueueRepository repository) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: StoryLauncher(repository: repository),
    ),
  );
  await tester.pumpAndSettle();
  tester
      .widget<CachePage>(find.byType(CachePage, skipOffstage: false))
      .onBrowse();
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('chapter-测试章节')));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('${repository.entries.first.title}的更多操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('缓存'));
  await tester.pump();
}

Future<void> finishQueue(
  WidgetTester tester,
  QueueRepository repository,
) async {
  for (var i = 0; i < 20; i++) {
    for (final release in repository.releases.values.toList()) {
      if (!release.isCompleted) release.complete();
    }
    await tester.pump();
    if (!tester
        .widget<CachePage>(find.byType(CachePage, skipOffstage: false))
        .caching) {
      break;
    }
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('缓存任务进度与总进度随资源更新，不显示分类与底部缓存按钮', (tester) async {
    const entry = StoryEntry('进度测试', 'progress');
    final job = CacheJob(entry)
      ..status = CacheJobStatus.downloading
      ..done = 1
      ..total = 4;
    Future<void> render() => tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: page(jobs: {entry.path: job}, caching: true)),
      ),
    );
    await render();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    final label = tester.element(find.text('进度测试'));
    final theme = Theme.of(label).progressIndicatorTheme;
    expect(theme.color, isNot(theme.linearTrackColor));
    expect(
      tester
          .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .map((bar) => bar.value),
      [0.25, 0.25],
    );
    job.done = 3;
    await render();
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .map((bar) => bar.value),
      [0.75, 0.75],
    );
  });

  testWidgets('下载任务与已缓存篇章同页显示，已完成任务不重复且可批量删除', (tester) async {
    const first = StoryEntry('第一幕', 'first');
    const second = StoryEntry('第二幕', 'second');
    List<StoryEntry>? deleted;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: page(
            caching: true,
            cached: [first, second],
            jobs: {
              first.path: CacheJob(first)..status = CacheJobStatus.completed,
              'downloading':
                  CacheJob(const StoryEntry('正在下载的剧情', 'downloading'))
                    ..status = CacheJobStatus.downloading
                    ..done = 1
                    ..total = 2,
            },
            onDelete: (entries) => deleted = entries,
          ),
        ),
      ),
    );
    expect(find.text('正在下载的剧情'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('第一幕'), findsNothing);
    expect(find.byKey(const ValueKey('offline-其他离线剧情')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('offline-其他离线剧情')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pump();
    await tester.tap(find.text('删除选中 (2)'));
    expect(deleted, [first, second]);
  });

  testWidgets('单项缓存完成后显示已缓存并阻止重复缓存', (tester) async {
    final store = DesktopStore()..concurrency = 2;
    addTearDown(store.close);
    final repository = QueueRepository(store);
    await startQueue(tester, repository);
    expect(repository.started, [repository.entries.first.path]);
    await finishQueue(tester, repository);
    final cache = tester.widget<CachePage>(
      find.byType(CachePage, skipOffstage: false),
    );
    expect(cache.cached, hasLength(1));
    cache.onBrowse();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chapter-测试章节')));
    await tester.pumpAndSettle();
    expect(find.text('已缓存'), findsOneWidget);
    await tester.tap(find.byTooltip('${repository.entries.first.title}的更多操作'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuItem<String>>(
            find.widgetWithText(PopupMenuItem<String>, '已缓存'),
          )
          .enabled,
      isFalse,
    );
  });

  testWidgets('移动网络开始缓存先确认，拒绝不创建失败任务', (tester) async {
    final store = MobileStore();
    addTearDown(store.close);
    final repository = QueueRepository(store);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: StoryLauncher(repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<CachePage>(find.byType(CachePage, skipOffstage: false))
        .onBrowse();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chapter-测试章节')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('${repository.entries.first.title}的更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('使用移动数据缓存？'), findsOneWidget);
    await tester.tap(find.text('停止缓存'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(repository.started, isEmpty);
    final cache = tester.widget<CachePage>(
      find.byType(CachePage, skipOffstage: false),
    );
    expect(cache.caching, isFalse);
    expect(cache.jobs, isEmpty);
    expect(cache.message, contains('已停止缓存'));
    expect(find.textContaining('已停止缓存', skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单项下载任务可以暂停并取消', (tester) async {
    final store = DesktopStore()..concurrency = 3;
    addTearDown(store.close);
    final repository = QueueRepository(store);
    await startQueue(tester, repository);
    final cache = tester.widget<CachePage>(
      find.byType(CachePage, skipOffstage: false),
    );
    final job = cache.jobs[repository.entries.first.path]!;
    cache.onToggleJob(job);
    await tester.pump();
    expect(job.control.paused, isTrue);
    cache.onRemoveJob(job);
    await tester.pump();
    await finishQueue(tester, repository);
    expect(repository.offline, isEmpty);
  });

  testWidgets('下载中可继续添加其他缓存任务并保持并行下载', (tester) async {
    final store = DesktopStore()..concurrency = 2;
    addTearDown(store.close);
    final repository = QueueRepository(store);
    await startQueue(tester, repository);
    // 首个任务下载中，菜单「缓存」对其他剧情仍然可用。
    await tester.tap(find.byTooltip('${repository.entries[1].title}的更多操作'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuItem<String>>(
            find.widgetWithText(PopupMenuItem<String>, '缓存'),
          )
          .enabled,
      isTrue,
    );
    await tester.tap(find.text('缓存'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(repository.started, hasLength(2));
    final cache = tester.widget<CachePage>(
      find.byType(CachePage, skipOffstage: false),
    );
    expect(cache.jobs, hasLength(2));
    expect(cache.caching, isTrue);
    // 两个任务并行下载，剧情馆行内都出现「缓存中」标识。
    expect(
      cache.jobs.values
          .where((job) => job.status == CacheJobStatus.downloading),
      hasLength(2),
    );
    expect(find.text('缓存中'), findsNWidgets(2));
    await finishQueue(tester, repository);
    expect(repository.offline, hasLength(2));
    expect(
      cache.jobs.values
          .every((job) => job.status == CacheJobStatus.completed),
      isTrue,
    );
    expect(
      tester
          .widget<CachePage>(find.byType(CachePage, skipOffstage: false))
          .caching,
      isFalse,
    );
  });

  testWidgets('下载中可从缓存页播放已缓存剧情，后台任务继续', (tester) async {
    final store = DesktopStore()..concurrency = 2;
    addTearDown(store.close);
    final repository = PlayQueueRepository(store);
    repository.offline.add(repository.entries[5].path);
    await startQueue(tester, repository);
    await tester.tap(find.text('离线与缓存').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('offline-测试章节')));
    await tester.pumpAndSettle();
    final play = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.play_arrow),
    );
    expect(play.onPressed, isNotNull);
    await tester.tap(find.byTooltip('播放 ${repository.entries[5].title}'));
    await tester.pump();
    // 播放器开始画面有持续动画，用轮询等待而不是 pumpAndSettle。
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.text('开始播放').evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    // 播放器正常打开，不再提示等待批量缓存完成。
    expect(repository.loaded, [repository.entries[5].path]);
    expect(find.text('请等待批量缓存完成后播放。'), findsNothing);
    expect(find.text('开始播放'), findsOneWidget);
    final cache = tester.widget<CachePage>(
      find.byType(CachePage, skipOffstage: false),
    );
    expect(cache.caching, isTrue);
    // 退出播放器后后台任务不受影响，继续完成。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await finishQueue(tester, repository);
    expect(repository.offline, hasLength(2));
  });

  testWidgets('Wi-Fi 转移动网络暂停全部任务，只弹一次，确认后继续', (tester) async {
    final store = MobileStore()
      ..connections = [ConnectivityResult.wifi]
      ..concurrency = 2;
    addTearDown(store.close);
    final repository = QueueRepository(store);
    await startQueue(tester, repository);
    final cache = tester.widget<CachePage>(
      find.byType(CachePage, skipOffstage: false),
    );
    expect(repository.started, hasLength(1));
    store.changes.add([ConnectivityResult.mobile]);
    store.changes.add([ConnectivityResult.mobile]);
    await tester.pumpAndSettle();
    expect(find.text('使用移动数据缓存？'), findsOneWidget);
    expect(cache.jobs.values.every((job) => job.control.blocked), isTrue);
    await tester.tap(find.text('继续缓存'));
    await tester.pumpAndSettle();
    expect(
      cache.jobs.values.where((job) => !job.control.blocked),
      hasLength(1),
    );
    store.changes.add([ConnectivityResult.mobile]);
    await tester.pump();
    expect(find.text('使用移动数据缓存？'), findsNothing);
    await finishQueue(tester, repository);
    expect(repository.offline, hasLength(1));
  });

  testWidgets('移动网络确认继续后启动并完成任务', (tester) async {
    final store = MobileStore();
    addTearDown(store.close);
    final repository = QueueRepository(store);
    await startQueue(tester, repository);
    await tester.pump(const Duration(milliseconds: 350));
    expect(repository.started, isEmpty);
    await tester.tap(find.text('继续缓存'));
    await tester.pumpAndSettle();
    expect(repository.started, hasLength(1));
    await finishQueue(tester, repository);
    expect(repository.offline, hasLength(1));
  });

  testWidgets('勾选不再提示后记住批准，重启会话不再弹确认框', (tester) async {
    final store = MobileStore();
    addTearDown(store.close);
    final repository = QueueRepository(store);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: StoryLauncher(repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<CachePage>(find.byType(CachePage, skipOffstage: false))
        .onBrowse();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chapter-测试章节')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('${repository.entries.first.title}的更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('使用移动数据缓存？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mobile-data-dont-ask')));
    await tester.pump();
    await tester.tap(find.text('继续缓存'));
    await tester.pumpAndSettle();
    expect(repository.started, hasLength(1));
    await finishQueue(tester, repository);
    expect(repository.offline, hasLength(1));
    expect(store.mobileDataApproved, isTrue);
    // 同一存储重新挂载（模拟重启读取持久化偏好）后，新任务不再弹确认框。
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: StoryLauncher(repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<CachePage>(find.byType(CachePage, skipOffstage: false))
        .onBrowse();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chapter-测试章节')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('${repository.entries[1].title}的更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存'));
    await tester.pumpAndSettle();
    expect(find.text('使用移动数据缓存？'), findsNothing);
    expect(repository.started, hasLength(2));
    await finishQueue(tester, repository);
    expect(repository.offline, hasLength(2));
  });

  testWidgets('拒绝移动数据不记住勾选，下次仍会提示', (tester) async {
    final store = MobileStore();
    addTearDown(store.close);
    final repository = QueueRepository(store);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: StoryLauncher(repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<CachePage>(find.byType(CachePage, skipOffstage: false))
        .onBrowse();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chapter-测试章节')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('${repository.entries.first.title}的更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('使用移动数据缓存？'), findsOneWidget);
    // 勾选「不再提示」后选择停止，也不应持久化批准。
    await tester.tap(find.byKey(const ValueKey('mobile-data-dont-ask')));
    await tester.pump();
    await tester.tap(find.text('停止缓存'));
    await tester.pump(const Duration(seconds: 1));
    expect(repository.started, isEmpty);
    expect(store.mobileDataApproved, isFalse);
    // 重新挂载后再次缓存，确认框照常弹出。
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: StoryLauncher(repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<CachePage>(find.byType(CachePage, skipOffstage: false))
        .onBrowse();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chapter-测试章节')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('${repository.entries.first.title}的更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('使用移动数据缓存？'), findsOneWidget);
    await tester.tap(find.text('停止缓存'));
    await tester.pump(const Duration(seconds: 1));
    expect(repository.started, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置页关闭移动数据提示开关后，缓存不再弹确认框', (tester) async {
    final store = MobileStore();
    addTearDown(store.close);
    final repository = QueueRepository(store);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: StoryLauncher(repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统设置').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('存储与缓存'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('setting-移动数据缓存提示')),
    );
    await tester.tap(find.byKey(const ValueKey('setting-移动数据缓存提示')));
    await tester.pump();
    expect(store.mobileDataApproved, isTrue);
    await tester.tap(find.text('剧情馆').last);
    await tester.pumpAndSettle();
    tester
        .widget<CachePage>(find.byType(CachePage, skipOffstage: false))
        .onBrowse();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chapter-测试章节')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('${repository.entries.first.title}的更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存'));
    await tester.pumpAndSettle();
    expect(find.text('使用移动数据缓存？'), findsNothing);
    expect(repository.started, hasLength(1));
    await finishQueue(tester, repository);
    expect(repository.offline, hasLength(1));
  });

  testWidgets('下载中仍可批量删除已离线剧情', (tester) async {
    const entry = StoryEntry('已离线', 'offline');
    List<StoryEntry>? deleted;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: page(
            caching: true,
            cached: [entry],
            onDelete: (entries) => deleted = entries,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('offline-其他离线剧情')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pump();
    await tester.tap(find.text('删除选中 (1)'));
    expect(deleted, [entry]);
  });
  testWidgets('拒绝 Wi-Fi 转移动网络会停止剩余任务，不复活离线记录', (tester) async {
    final store = MobileStore()
      ..connections = [ConnectivityResult.wifi]
      ..concurrency = 2;
    addTearDown(store.close);
    final repository = QueueRepository(store);
    await startQueue(tester, repository);
    store.changes.add([ConnectivityResult.mobile]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止缓存'));
    await tester.pump();
    await finishQueue(tester, repository);
    final cache = tester.widget<CachePage>(
      find.byType(CachePage, skipOffstage: false),
    );
    expect(cache.caching, isFalse);
    expect(
      cache.jobs.values.every((job) => job.status == CacheJobStatus.cancelled),
      isTrue,
    );
    expect(repository.offline, isEmpty);
    expect(cache.message, contains('已停止缓存'));
  });

  testWidgets('设置页下载中并发可调，目录与清空保持锁定', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            concurrency: 3,
            onConcurrencyChanged: (_) {},
            isMobile: true,
            isDesktop: false,
            caching: true,
            directoryBusy: true,
            onClearCache: () {},
            onOpenDirectory: () {},
            onMoveDirectory: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('存储与缓存'));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('setting-并发下载数')),
    );
    expect(slider.onChanged, isNotNull);
    final clear = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '清空素材缓存'),
    );
    expect(clear.onPressed, isNull);
    expect(find.text('仅在 Wi-Fi 下下载'), findsNothing);
  });

  test('清理后保留剧情目录和设置，清除素材、内存和离线记录', () async {
    final cache = MemoryCache();
    final store = AssetStore(
      cache: cache,
      client: MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(
            request.url.path.endsWith('.txt') ? '[name="甲"]对白' : '{}',
          ),
          200,
        ),
      ),
    );
    addTearDown(store.close);
    await store.setConcurrency(2);
    final repository = StoryRepository(store);
    const entry = StoryEntry('测试', 'test/story');
    expect(await repository.cacheEntry(entry), isEmpty);
    final uri = StoryRepository.storyBase.resolve('test/story.txt');
    await store.load(uri);
    expect(store.peek(uri), isNotNull);
    await repository.clearCache();
    expect(await cache.read(uri), isNull);
    expect(store.peek(uri), isNull);
    expect(await repository.cachedStories(), isEmpty);
    expect(await cache.read(StoryRepository.indexUri), isNotNull);
    final restored = AssetStore(cache: cache);
    addTearDown(restored.close);
    await restored.loadSettings();
    expect(restored.concurrency, 2);
    await cache.write(uri, Uint8List.fromList([1]));
    expect(await cache.read(uri), [1]);
  });
}
