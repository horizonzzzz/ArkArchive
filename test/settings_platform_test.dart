import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/app/settings_page.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';

void main() {
  for (final platform in TargetPlatform.values) {
    testWidgets('$platform 仅显示当前平台可用的缓存设置', (tester) async {
      final store = AssetStore();
      addTearDown(store.close);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsPage(
        concurrency: 4,
        onConcurrencyChanged: (_) {},
        isMobile: store.isMobile,
        isDesktop: store.isDesktop,
        wifiOnly: true,
        onWifiOnlyChanged: (_) {},
        caching: false,
        onOpenDirectory: () {},
        onMoveDirectory: () {},
        directoryBusy: false,
        cacheBytes: 1048576,
        cacheLocation: '/cache',
      ))));
      final mobile = platform == TargetPlatform.android || platform == TargetPlatform.iOS;
      final desktop = platform == TargetPlatform.windows || platform == TargetPlatform.macOS || platform == TargetPlatform.linux;
      expect(find.text('仅在 Wi-Fi 下下载'), mobile ? findsOneWidget : findsNothing);
      expect(find.text('打开目录'), desktop ? findsOneWidget : findsNothing);
      expect(find.text('更改目录'), desktop ? findsOneWidget : findsNothing);
      expect(find.text('/cache'), desktop ? findsOneWidget : findsNothing);
      expect(find.text('缓存占用：1.0 MB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }
}
