import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/app/cache_job.dart';
import 'package:arknights_story_player/app/cache_page.dart';
import 'package:arknights_story_player/app/settings_page.dart';
import 'package:arknights_story_player/story_player/data/story_repository.dart';

void main() {
  testWidgets('离线按活动下钻，播放和批量删除只作用当前活动', (tester) async {
    const first = StoryEntry('甲幕', 'a/1');
    const second = StoryEntry('乙幕', 'b/1');
    const extra = StoryEntry('未归类幕', 'unknown');
    var cached = [first, second, extra];
    StoryEntry? opened;
    List<StoryEntry>? deleted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => CachePage(
              groups: const [
                StoryGroup('活动甲', [first]),
                StoryGroup('活动乙', [second]),
              ],
              cached: cached,
              jobs: const {},
              onBrowse: () {},
              onRetry: (_) {},
              onOpen: (entry) => opened = entry,
              onToggleJob: (_) {},
              onRemoveJob: (_) {},
              onDeleteCached: (entries) => update(() {
                deleted = entries;
                cached = cached
                    .where((entry) => !entries.contains(entry))
                    .toList();
              }),
              deleting: false,
              caching: false,
              done: 0,
              total: 0,
            ),
          ),
        ),
      ),
    );
    expect(find.text('甲幕'), findsNothing);
    expect(find.text('其他离线剧情'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('offline-活动甲')));
    await tester.pumpAndSettle();
    expect(find.text('甲幕'), findsOneWidget);
    expect(find.text('乙幕'), findsNothing);
    await tester.tap(find.byTooltip('播放 甲幕'));
    expect(opened, first);
    await tester.tap(find.text('批量管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pump();
    await tester.tap(find.text('删除选中 (1)'));
    await tester.pumpAndSettle();
    expect(deleted, [first]);
    expect(cached, [second, extra]);
    expect(find.text('暂无离线档案'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('offline-活动甲')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('offline-活动乙')));
    await tester.pumpAndSettle();
    expect(find.text('乙幕'), findsOneWidget);
    expect(find.text('删除选中 (1)'), findsNothing);
    await tester.tap(find.byTooltip('返回离线与缓存'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('offline-活动乙')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已缓存剧情有观看进度时行内显示继续观看标识', (tester) async {
    const first = StoryEntry('甲幕', 'a/1');
    const second = StoryEntry('乙幕', 'b/1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CachePage(
            groups: const [
              StoryGroup('活动甲', [first]),
              StoryGroup('活动乙', [second]),
            ],
            cached: const [first, second],
            progressPaths: const {'a/1'},
            completedPaths: const {'a/1', 'b/1'},
            jobs: const {},
            onBrowse: () {},
            onRetry: (_) {},
            onOpen: (_) {},
            onToggleJob: (_) {},
            onRemoveJob: (_) {},
            onDeleteCached: (_) {},
            deleting: false,
            caching: false,
            done: 0,
            total: 0,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('offline-活动甲')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('continue-a/1')), findsOneWidget);
    expect(find.byKey(const ValueKey('completed-a/1')), findsNothing);
    await tester.tap(find.byTooltip('返回离线与缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('offline-活动乙')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('continue-b/1')), findsNothing);
    expect(find.byKey(const ValueKey('completed-b/1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单幕缓存可暂停、恢复和移除', (tester) async {
    const entry = StoryEntry('测试剧情', 'test/story');
    final job = CacheJob(entry)
      ..status = CacheJobStatus.downloading
      ..started = true
      ..done = 1
      ..total = 4;
    var visible = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) {
              return CachePage(
                cached: const [],
                jobs: visible ? {entry.path: job} : {},
                onBrowse: () {},
                onRetry: (_) {},
                onOpen: (_) {},
                onDeleteCached: (_) {},
                onToggleJob: (item) => update(() {
                  if (item.control.paused) {
                    item.control.resume();
                    item.status = CacheJobStatus.downloading;
                  } else {
                    item.control.pause();
                    item.status = CacheJobStatus.paused;
                  }
                }),
                onRemoveJob: (item) => update(() {
                  item.control.cancel();
                  visible = false;
                }),
                deleting: false,
                caching: true,
                done: 0,
                total: 1,
              );
            },
          ),
        ),
      ),
    );
    expect(find.text('1 / 4'), findsOneWidget);
    await tester.tap(find.byTooltip('暂停 测试剧情'));
    await tester.pump();
    expect(job.control.paused, isTrue);
    expect(find.text('已暂停'), findsOneWidget);
    await tester.tap(find.byTooltip('恢复 测试剧情'));
    await tester.pump();
    expect(job.control.paused, isFalse);
    await tester.tap(find.byTooltip('删除任务 测试剧情'));
    await tester.pump();
    expect(job.control.cancelled, isTrue);
    expect(find.text('测试剧情'), findsNothing);
  });

  testWidgets('下载中已缓存条目仍可播放，失败任务可直接重试', (tester) async {
    const cached = StoryEntry('已缓存剧情', 'a/1');
    final failed = CacheJob(const StoryEntry('失败剧情', 'b/1'))
      ..status = CacheJobStatus.failed
      ..error = '网络不可用';
    StoryEntry? opened;
    CacheJob? retried;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CachePage(
            cached: const [cached],
            jobs: {failed.entry.path: failed},
            onBrowse: () {},
            onRetry: (job) => retried = job,
            onOpen: (entry) => opened = entry,
            onToggleJob: (_) {},
            onRemoveJob: (_) {},
            onDeleteCached: (_) {},
            deleting: false,
            caching: true,
            done: 0,
            total: 1,
          ),
        ),
      ),
    );
    // 总览页：下载中失败任务也显示重试按钮。
    final retry = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.refresh),
    );
    expect(retry.onPressed, isNotNull);
    await tester.tap(find.byTooltip('重试失败任务'));
    await tester.pump();
    expect(retried, same(failed));
    // 下钻后：已缓存条目在下载中仍可播放。
    await tester.tap(find.byKey(const ValueKey('offline-其他离线剧情')));
    await tester.pumpAndSettle();
    final play = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.play_arrow),
    );
    expect(play.onPressed, isNotNull);
    await tester.tap(find.byTooltip('播放 ${cached.title}'));
    await tester.pump();
    expect(opened, cached);
    expect(tester.takeException(), isNull);
  });

  for (final mobile in [true, false]) {
    testWidgets(mobile ? '移动端显示流量确认说明' : '桌面端只显示缓存目录', (tester) async {
      var cleared = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) {
                return SettingsPage(
                  concurrency: 4,
                  onConcurrencyChanged: (_) {},
                  isMobile: mobile,
                  isDesktop: !mobile,
                  caching: false,
                  onOpenDirectory: () {},
                  onClearCache: () => cleared = true,
                  onMoveDirectory: () {},
                  directoryBusy: false,
                  cacheBytes: 1024,
                  cacheLocation: 'C:/cache',
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('缓存设置'));
      await tester.pumpAndSettle();
      expect(
        find.text('关闭后，使用移动数据缓存前不再弹窗确认。'),
        mobile ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('setting-移动数据缓存提示')),
        mobile ? findsOneWidget : findsNothing,
      );
      expect(find.text('本地媒体缓存目录'), mobile ? findsNothing : findsOneWidget);
      expect(find.text('C:/cache'), mobile ? findsNothing : findsOneWidget);
      await tester.ensureVisible(find.text('清空素材缓存'));
      await tester.tap(find.text('清空素材缓存'));
      expect(cleared, isTrue);
    });
  }
}
