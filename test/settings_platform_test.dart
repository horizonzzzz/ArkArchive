import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/app/settings_page.dart';
import 'package:arknights_story_player/app/app_theme.dart';
import 'package:arknights_story_player/story_player/data/playback_settings.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';

void main() {
  testWidgets('切换主题立即更新颜色并保留当前设置页面', (tester) async {
    var settings = const PlaybackSettings();
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          theme: buildAppTheme(light: settings.lightTheme),
          home: Scaffold(
            body: SettingsPage(
              concurrency: 4,
              onConcurrencyChanged: (_) {},
              isMobile: false,
              isDesktop: false,
              caching: false,
              onOpenDirectory: () {},
              onMoveDirectory: () {},
              onClearCache: () {},
              directoryBusy: false,
              settings: settings,
              onSettingsChanged: (value) => setState(() => settings = value),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('基础设置'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('setting-light-theme'));
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(Theme.of(tester.element(toggle)).brightness, Brightness.dark);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(settings.lightTheme, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(Theme.of(tester.element(toggle)).brightness, Brightness.light);
    expect(
      AppColors.of(tester.element(toggle)).canvas,
      const Color(0xfff5f5f5),
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(settings.lightTheme, isFalse);
    expect(Theme.of(tester.element(toggle)).brightness, Brightness.dark);
  });
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
      await tester.tap(find.text('缓存设置'));
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
    final categories = ['基础设置', '缓存设置', '网络设置', '关于'];
    final positions = categories
        .map((label) => tester.getTopLeft(find.text(label)).dy)
        .toList();
    expect(positions, orderedEquals([...positions]..sort()));
    expect(find.text('主音量'), findsNothing);
    await tester.tap(find.text('基础设置'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setting-light-theme')), findsOneWidget);
    expect(find.byKey(const ValueKey('setting-自动播放等待')), findsOneWidget);
    expect(find.byKey(const ValueKey('setting-逐字出字间隔')), findsOneWidget);
    expect(find.text('语音 Voice（预留）'), findsNothing);
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('setting-主音量')),
    );
    slider.onChanged!(.3 * 100);
    await tester.pump();
    expect(master, .3);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('网络设置'));
    await tester.pumpAndSettle();
    // 进入分类自动执行一次诊断，无需手动点击。
    expect(requests, hasLength(2));
    expect(find.text('连接成功'), findsOneWidget);
    expect(find.text('连接失败'), findsOneWidget);
    // 手动按钮保留，用于再次检测。
    await tester.tap(find.text('重新检测'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(4));
    expect(find.text('连接失败'), findsNWidgets(2));
    expect(find.text('强制离线模式'), findsNothing);
  });
}
