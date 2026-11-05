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
import 'package:arknights_story_player/story_player/data/story_repository.dart';

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
  Future<bool> deleteCachedStory(StoryEntry entry) async =>
      offline.remove(entry.path);
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
  onRetry: () {},
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
  await tester.tap(find.text('选择'));
  await tester.pump();
  await tester.ensureVisible(find.text('全选本章'));
  await tester.tap(find.text('全选本章'));
  await tester.pump();
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
    await tester.pump();
    await tester.tap(find.text('全选'));
    await tester.pump();
    await tester.tap(find.text('删除选中 (2)'));
    expect(deleted, [first, second]);
  });

  testWidgets('剧情队列按设置启动，完成后更新剧情馆并阻止重复选择', (tester) async {
    final store = DesktopStore()..concurrency = 2;
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
    await tester.tap(find.text('选择'));
    await tester.pump();
    await tester.ensureVisible(find.text('全选本章'));
    await tester.tap(find.text('全选本章'));
    await tester.pump();
    await tester.tap(find.text('缓存'));
    await tester.pump();
    expect(repository.started, hasLength(2));
    expect(
      tester
          .widget<CachePage>(find.byType(CachePage))
          .jobs
          .values
          .where((job) => job.status == CacheJobStatus.waiting),
      hasLength(4),
    );
    final queued = tester.widget<CachePage>(find.byType(CachePage));
    final paused = queued.jobs[repository.entries[2].path]!;
    queued.onToggleJob(paused);
    repository.releases.values.first.complete();
    await tester.pump();
    expect(repository.started, hasLength(3));
    expect(repository.started.last, repository.entries[3].path);
    queued.onToggleJob(paused);
    while (repository.started.length < 6 ||
        repository.releases.values.any((release) => !release.isCompleted)) {
      for (final release in repository.releases.values.toList()) {
        if (!release.isCompleted) release.complete();
      }
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final cache = tester.widget<CachePage>(find.byType(CachePage));
    expect(
      cache.jobs.values.every((job) => job.status == CacheJobStatus.completed),
      isTrue,
    );
    expect(cache.cached, hasLength(6));
    cache.onBrowse();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chapter-测试章节')));
    await tester.pumpAndSettle();
    expect(find.text('已缓存'), findsWidgets);
    expect(find.byType(Checkbox), findsNothing);
    final select = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '选择'),
    );
    expect(select.onPressed, isNull);
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
    await tester.tap(find.text('选择'));
    await tester.pump();
    await tester.ensureVisible(find.text('全选本章'));
    await tester.tap(find.text('全选本章'));
    await tester.pump();
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

  testWidgets('运行中降低并发暂停超额任务，调高不恢复手动暂停', (tester) async {
    final store = DesktopStore()..concurrency = 3;
    addTearDown(store.close);
    final repository = QueueRepository(store);
    await startQueue(tester, repository);
    var cache = tester.widget<CachePage>(find.byType(CachePage));
    expect(repository.started, hasLength(3));
    final settings = tester.widget<SettingsPage>(
      find.byType(SettingsPage, skipOffstage: false),
    );
    settings.onConcurrencyChanged(2);
    await tester.pump();
    expect(cache.jobs['test/2']!.control.blocked, isTrue);
    expect(cache.jobs['test/2']!.control.paused, isFalse);
    expect(cache.jobs['test/2']!.status, CacheJobStatus.waiting);
    cache.onToggleJob(cache.jobs['test/0']!);
    await tester.pump();
    expect(cache.jobs['test/0']!.control.paused, isTrue);
    expect(cache.jobs['test/2']!.control.blocked, isFalse);
    settings.onConcurrencyChanged(3);
    await tester.pump();
    expect(cache.jobs['test/0']!.control.blocked, isTrue);
    expect(repository.started, hasLength(4));
    cache.onRemoveJob(cache.jobs['test/0']!);
    await tester.pump();
    await finishQueue(tester, repository);
    cache = tester.widget<CachePage>(find.byType(CachePage));
    expect(cache.caching, isFalse);
    expect(repository.offline, isNot(contains('test/0')));
    expect(cache.cached, hasLength(5));
  });

  testWidgets('Wi-Fi 转移动网络暂停全部任务，只弹一次，确认后继续', (tester) async {
    final store = MobileStore()
      ..connections = [ConnectivityResult.wifi]
      ..concurrency = 2;
    addTearDown(store.close);
    final repository = QueueRepository(store);
    await startQueue(tester, repository);
    final cache = tester.widget<CachePage>(find.byType(CachePage));
    expect(repository.started, hasLength(2));
    store.changes.add([ConnectivityResult.mobile]);
    store.changes.add([ConnectivityResult.mobile]);
    await tester.pumpAndSettle();
    expect(find.text('使用移动数据缓存？'), findsOneWidget);
    expect(cache.jobs.values.every((job) => job.control.blocked), isTrue);
    await tester.tap(find.text('继续缓存'));
    await tester.pumpAndSettle();
    expect(
      cache.jobs.values.where((job) => !job.control.blocked),
      hasLength(2),
    );
    store.changes.add([ConnectivityResult.mobile]);
    await tester.pump();
    expect(find.text('使用移动数据缓存？'), findsNothing);
    await finishQueue(tester, repository);
    expect(repository.offline, hasLength(6));
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
    expect(repository.started, hasLength(4));
    await finishQueue(tester, repository);
    expect(repository.offline, hasLength(6));
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
    await tester.pump();
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
    final cache = tester.widget<CachePage>(find.byType(CachePage));
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
