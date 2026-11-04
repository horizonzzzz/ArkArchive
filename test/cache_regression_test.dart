import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:arknights_story_player/app/app_theme.dart';
import 'package:arknights_story_player/app/cache_job.dart';
import 'package:arknights_story_player/app/cache_page.dart';
import 'package:arknights_story_player/app/story_launcher.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/data/cache_control.dart';
import 'package:arknights_story_player/story_player/data/story_repository.dart';

import 'data_test.dart' show MemoryCache;

class RestrictedStore extends AssetStore {
  RestrictedStore() : super(cache: MemoryCache());
  @override
  Future<void> checkCacheNetwork() async => throw const WifiRequired();
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
    offline.add(entry.path);
    return [];
  }
}

CachePage page({
  List<StoryEntry> selected = const [],
  List<StoryEntry> cached = const [],
  Map<String, CacheJob> jobs = const {},
  bool caching = false,
  ValueChanged<List<StoryEntry>>? onDelete,
}) => CachePage(
  selected: selected,
  cached: cached,
  jobs: jobs,
  caching: caching,
  deleting: false,
  done: 0,
  total: jobs.length,
  onBrowse: () {},
  onCache: () {},
  onOpen: (_) {},
  onToggleJob: (_) {},
  onRemoveJob: (_) {},
  onDeleteCached: onDelete ?? (_) {},
);

void main() {
  testWidgets('选中标签保持反白对比，任务进度与总进度随资源更新', (tester) async {
    const entry = StoryEntry('进度测试', 'progress');
    final job = CacheJob(entry)
      ..status = CacheJobStatus.downloading
      ..done = 1
      ..total = 4;
    Future<void> render() => tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: page(selected: [entry], jobs: {entry.path: job}, caching: true),
        ),
      ),
    );
    await render();
    final label = tester.element(find.text('待缓存 (1)'));
    expect(DefaultTextStyle.of(label).style.color, AppColors.onActive);
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

  testWidgets('已完成任务从待缓存移除，已离线支持选择和批量删除', (tester) async {
    const first = StoryEntry('第一幕', 'first');
    const second = StoryEntry('第二幕', 'second');
    List<StoryEntry>? deleted;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: page(
            selected: [first],
            cached: [first, second],
            jobs: {
              first.path: CacheJob(first)..status = CacheJobStatus.completed,
            },
            onDelete: (entries) => deleted = entries,
          ),
        ),
      ),
    );
    expect(find.text('待缓存 (0)'), findsOneWidget);
    expect(find.text('第一幕'), findsNothing);
    await tester.tap(find.text('已离线'));
    await tester.pumpAndSettle();
    expect(
      DefaultTextStyle.of(tester.element(find.text('已离线'))).style.color,
      AppColors.onActive,
    );
    await tester.tap(find.text('批量管理'));
    await tester.pump();
    await tester.tap(find.text('全选'));
    await tester.pump();
    await tester.tap(find.text('删除选中 (2)'));
    expect(deleted, [first, second]);
  });

  testWidgets('剧情队列按设置启动，完成后更新剧情馆并阻止重复选择', (tester) async {
    final store = AssetStore(cache: MemoryCache())..concurrency = 2;
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
    await tester.ensureVisible(find.text('全选本章'));
    await tester.tap(find.text('全选本章'));
    await tester.pump();
    tester
        .widget<CachePage>(find.byType(CachePage, skipOffstage: false))
        .onCache();
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
    expect(cache.selected, isEmpty);
    expect(cache.cached, hasLength(6));
    cache.onBrowse();
    await tester.pumpAndSettle();
    expect(find.text('已缓存'), findsWidgets);
    final checks = tester.widgetList<Checkbox>(find.byType(Checkbox));
    expect(checks, isNotEmpty);
    expect(checks.every((check) => check.onChanged == null), isTrue);
  });

  testWidgets('Wi-Fi 拦截显示提示，不创建失败任务', (tester) async {
    final store = RestrictedStore();
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
    await tester.ensureVisible(find.text('全选本章'));
    await tester.tap(find.text('全选本章'));
    await tester.pump();
    tester
        .widget<CachePage>(find.byType(CachePage, skipOffstage: false))
        .onCache();
    await tester.pump();
    expect(repository.started, isEmpty);
    final cache = tester.widget<CachePage>(
      find.byType(CachePage, skipOffstage: false),
    );
    expect(cache.caching, isFalse);
    expect(cache.jobs, isEmpty);
    expect(cache.message, contains('当前未连接 Wi-Fi'));
    expect(find.textContaining('当前未连接 Wi-Fi'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    await store.setWifiOnly(true);
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
    expect(restored.wifiOnly, isTrue);
    await cache.write(uri, Uint8List.fromList([1]));
    expect(await cache.read(uri), [1]);
  });
}
