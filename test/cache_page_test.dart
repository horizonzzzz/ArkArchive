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
              selected: const [],
              cached: cached,
              jobs: const {},
              onBrowse: () {},
              onCache: () {},
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
    await tester.tap(find.text('已离线'));
    await tester.pumpAndSettle();
    expect(find.text('甲幕'), findsNothing);
    expect(find.text('其他离线剧情'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('offline-活动甲')));
    await tester.pumpAndSettle();
    expect(find.text('甲幕'), findsOneWidget);
    expect(find.text('乙幕'), findsNothing);
    await tester.tap(find.byTooltip('播放 甲幕'));
    expect(opened, first);
    await tester.tap(find.text('批量管理'));
    await tester.pump();
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
    await tester.tap(find.text('返回已离线'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('offline-活动乙')), findsOneWidget);
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
                selected: visible ? [entry] : [],
                cached: const [],
                jobs: visible ? {entry.path: job} : {},
                onBrowse: () {},
                onCache: () {},
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
      expect(
        find.text('使用移动数据缓存前会提示确认。'),
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
