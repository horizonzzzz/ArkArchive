import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/app/cache_job.dart';
import 'package:arknights_story_player/app/cache_page.dart';
import 'package:arknights_story_player/app/settings_page.dart';
import 'package:arknights_story_player/story_player/data/story_repository.dart';

void main() {
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
    testWidgets(mobile ? '移动端只显示 Wi-Fi 设置' : '桌面端只显示缓存目录', (tester) async {
      var wifi = false;
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
                  wifiOnly: wifi,
                  onWifiOnlyChanged: (value) => update(() => wifi = value),
                  caching: false,
                  onOpenDirectory: () {},
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
      expect(find.text('仅在 Wi-Fi 下下载'), mobile ? findsOneWidget : findsNothing);
      expect(find.text('本地媒体缓存目录'), mobile ? findsNothing : findsOneWidget);
      expect(find.text('C:/cache'), mobile ? findsNothing : findsOneWidget);
      if (mobile) {
        final row = find
            .ancestor(of: find.text('仅在 Wi-Fi 下下载'), matching: find.byType(Row))
            .first;
        final toggle = find.descendant(of: row, matching: find.byType(Switch));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pump();
        expect(wifi, isTrue);
      }
    });
  }
}
