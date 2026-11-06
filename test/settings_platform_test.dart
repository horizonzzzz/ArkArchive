import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/app/settings_page.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';

void main() {
  for (final platform in TargetPlatform.values) {
    testWidgets('$platform 仅显示当前平台可用的缓存设置', (tester) async {
      final store = AssetStore();
      addTearDown(store.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              concurrency: 4,
              onConcurrencyChanged: (_) {},
              isMobile: store.isMobile,
              isDesktop: store.isDesktop,
              caching: false,
              onOpenDirectory: () {},
              onClearCache: () {},
              onMoveDirectory: () {},
              directoryBusy: false,
              cacheBytes: 1048576,
              cacheLocation: '/cache',
            ),
          ),
        ),
      );
      await tester.tap(find.text('存储与缓存'));
      await tester.pumpAndSettle();
      final mobile =
          platform == TargetPlatform.android || platform == TargetPlatform.iOS;
      final desktop =
          platform == TargetPlatform.windows ||
          platform == TargetPlatform.macOS ||
          platform == TargetPlatform.linux;
      expect(
        find.text('关闭后，使用移动数据缓存前不再弹窗确认。'),
        mobile ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('setting-移动数据缓存提示')),
        mobile ? findsOneWidget : findsNothing,
      );
      expect(find.text('打开目录'), desktop ? findsOneWidget : findsNothing);
      expect(find.text('更改目录'), desktop ? findsOneWidget : findsNothing);
      expect(find.text('/cache'), desktop ? findsOneWidget : findsNothing);
      expect(find.text('缓存占用：1.0 MB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }
  testWidgets('设置分类下钻、调整并诊断节点', (tester) async {
    final requests = <Uri>[];
    var master = 0.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            concurrency: 4,
            onConcurrencyChanged: (_) {},
            isMobile: false,
            isDesktop: false,
            caching: false,
            onOpenDirectory: () {},
            onMoveDirectory: () {},
            directoryBusy: false,
            onClearCache: () {},
            onSettingsChanged: (value) => master = value.master,
            probe: (uri) async {
              requests.add(uri);
              return requests.length == 1;
            },
          ),
        ),
      ),
    );
    expect(find.text('主音量'), findsNothing);
    await tester.tap(find.text('音频通道'));
    await tester.pumpAndSettle();
    expect(find.text('语音 Voice（预留）'), findsNothing);
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('setting-主音量')),
    );
    slider.onChanged!(.3 * 100);
    await tester.pump();
    expect(master, .3);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('网络与节点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接诊断'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    expect(find.text('连接成功'), findsOneWidget);
    expect(find.text('连接失败'), findsOneWidget);
    expect(find.text('强制离线模式'), findsNothing);
  });
}
