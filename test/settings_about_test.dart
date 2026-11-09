import 'dart:convert';
import 'dart:io';

import 'package:arknights_story_player/app/app_update.dart';
import 'package:arknights_story_player/app/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _releaseBody({
  String tag = 'v0.5.0',
  List<Map<String, Object>>? assets,
}) => jsonEncode({
  'tag_name': tag,
  'name': tag,
  'body': '修复若干问题。',
  'html_url':
      'https://github.com/horizonzzzz/ArkArchive/releases/tag/$tag',
  'assets': assets ?? [
    {
      'name': 'arknights_story_player-v0.5.0-windows-x64-setup.exe',
      'browser_download_url': 'https://example.com/setup.exe',
      'size': 2048,
    },
    {
      'name': 'arknights_story_player-v0.5.0-android-arm64-v8a.apk',
      'browser_download_url': 'https://example.com/arm64.apk',
      'size': 4096,
    },
  ],
});

/// 测试用文件后端：写入真实临时目录。
class _TestStore extends UpdateFileStore {
  _TestStore(this.directory);

  final Directory directory;

  @override
  Future<String?> downloadDirectory() async => directory.path;
}

http.Client _releaseClient({
  String tag = 'v0.5.0',
  List<Map<String, Object>>? assets,
}) => MockClient.streaming((
  request,
  bodyStream,
) async {
  if (request.url.host == 'example.com') {
    return http.StreamedResponse(
      Stream.value(utf8.encode('installer-bytes')),
      200,
      contentLength: 15,
    );
  }
  return http.StreamedResponse(
    Stream.value(utf8.encode(_releaseBody(tag: tag, assets: assets))),
    200,
  );
});

/// 同一次发布包含多个 Android 架构包时的资产清单。
List<Map<String, Object>> _androidAssets() => [
  {
    'name': 'arknights_story_player-v0.5.0-android-arm64-v8a.apk',
    'browser_download_url': 'https://example.com/arm64.apk',
    'size': 2048,
  },
  {
    'name': 'arknights_story_player-v0.5.0-android-x86_64.apk',
    'browser_download_url': 'https://example.com/x86_64.apk',
    'size': 2048,
  },
  {
    'name': 'arknights_story_player-v0.5.0-android-universal.apk',
    'browser_download_url': 'https://example.com/universal.apk',
    'size': 4096,
  },
];

Widget _host(SettingsPage page) =>
    MaterialApp(home: Scaffold(body: page));

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets('关于页检查更新并展示当前平台的安装包（$platform）', (tester) async {
      final directory = Directory.systemTemp.createTempSync('about-test');
      addTearDown(() {
        try {
          if (directory.existsSync()) directory.deleteSync(recursive: true);
        } catch (_) {
          // 刚写入的文件可能被杀毒或索引服务短暂占用；临时目录留在系统 Temp 不影响断言。
        }
      });
      final opened = <Uri>[];
      final client = AppUpdateClient(
        client: _releaseClient(),
        currentVersion: '0.4.0',
        files: _TestStore(directory),
      );
      addTearDown(client.close);
      final mobile = platform == TargetPlatform.android ||
          platform == TargetPlatform.iOS;
      await tester.pumpWidget(
        _host(
          SettingsPage(
            concurrency: 4,
            onConcurrencyChanged: (_) {},
            isMobile: mobile,
            isDesktop: platform == TargetPlatform.windows,
            caching: false,
            directoryBusy: false,
            onOpenDirectory: () {},
            onClearCache: () {},
            onMoveDirectory: () {},
            appVersion: '0.4.0',
            update: client,
            onOpenLink: opened.add,
          ),
        ),
      );
      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('about-version')), findsOneWidget);
      expect(find.text('v0.4.0'), findsOneWidget);
      expect(find.text('检查更新'), findsOneWidget);

      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('v0.5.0'), findsOneWidget);
      expect(find.text('修复若干问题。'), findsOneWidget);

      switch (platform) {
        case TargetPlatform.windows:
          expect(
            find.text('arknights_story_player-v0.5.0-windows-x64-setup.exe'),
            findsOneWidget,
          );
          expect(find.textContaining('android-arm64'), findsNothing);
          // 桌面端在应用内下载安装包并保存到下载目录。
          await tester.ensureVisible(
            find.text('arknights_story_player-v0.5.0-windows-x64-setup.exe'),
          );
          await tester.tap(find.text('下载'));
          // 真实文件 IO 需要在 runAsync 的真实事件循环中完成。
          await tester.runAsync(() async {
            final deadline = DateTime.now().add(const Duration(seconds: 5));
            while (find.text('已保存到下载目录').evaluate().isEmpty &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await tester.pump();
            }
          });
          expect(find.text('已保存到下载目录'), findsOneWidget);
          // 推进 SnackBar 的自动关闭计时器，避免残留 pending timer。
          await tester.pump(const Duration(seconds: 4));
          await tester.pumpAndSettle();
          expect(
            directory
                .listSync()
                .map((entity) => entity.path.split(Platform.pathSeparator).last),
            contains('arknights_story_player-v0.5.0-windows-x64-setup.exe'),
          );
        case TargetPlatform.android:
          expect(
            find.text('arknights_story_player-v0.5.0-android-arm64-v8a.apk'),
            findsOneWidget,
          );
          expect(find.textContaining('windows-x64'), findsNothing);
          // 移动端下载交给系统浏览器完成。
          await tester.ensureVisible(
            find.text('arknights_story_player-v0.5.0-android-arm64-v8a.apk'),
          );
          await tester.tap(find.byKey(const ValueKey(
            'about-download-arknights_story_player-v0.5.0-android-arm64-v8a.apk',
          )));
          expect(opened.single, Uri.parse('https://example.com/arm64.apk'));
        case TargetPlatform.iOS:
          expect(
            find.text('当前平台没有可自动匹配的安装包，请在发布页面查看全部文件。'),
            findsOneWidget,
          );
          await tester.ensureVisible(find.text('打开发布页面'));
          await tester.tap(find.text('打开发布页面'));
          expect(
            opened.single.toString(),
            'https://github.com/horizonzzzz/ArkArchive/releases/tag/v0.5.0',
          );
        default:
          fail('未预期的平台：$platform');
      }
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets('Android 自动按设备架构只提供一个下载按钮', (tester) async {
    final opened = <Uri>[];
    final client = AppUpdateClient(
      client: _releaseClient(assets: _androidAssets()),
      currentVersion: '0.4.0',
    );
    addTearDown(client.close);
    await tester.pumpWidget(
      _host(
        SettingsPage(
          concurrency: 4,
          onConcurrencyChanged: (_) {},
          isMobile: true,
          isDesktop: false,
          caching: false,
          directoryBusy: false,
          onOpenDirectory: () {},
          onClearCache: () {},
          onMoveDirectory: () {},
          appVersion: '0.4.0',
          update: client,
          androidAbi: 'arm64-v8a',
          onOpenLink: opened.add,
        ),
      ),
    );
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    // 只出现匹配设备架构的那一个下载按钮，其余架构与 universal 均不展示。
    expect(find.text('已自动匹配设备架构，直接下载安装即可。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey(
        'about-download-arknights_story_player-v0.5.0-android-arm64-v8a.apk',
      )),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey(
        'about-download-arknights_story_player-v0.5.0-android-x86_64.apk',
      )),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey(
        'about-download-arknights_story_player-v0.5.0-android-universal.apk',
      )),
      findsNothing,
    );
    // 安装包名完整展示，不再被省略号截断。
    expect(
      find.text('arknights_story_player-v0.5.0-android-arm64-v8a.apk'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey(
      'about-download-arknights_story_player-v0.5.0-android-arm64-v8a.apk',
    )));
    expect(opened.single, Uri.parse('https://example.com/arm64.apk'));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('Android 无法探测架构时回退 universal 并只给一个按钮', (tester) async {
    final opened = <Uri>[];
    final client = AppUpdateClient(
      client: _releaseClient(assets: _androidAssets()),
      currentVersion: '0.4.0',
    );
    addTearDown(client.close);
    await tester.pumpWidget(
      _host(
        SettingsPage(
          concurrency: 4,
          onConcurrencyChanged: (_) {},
          isMobile: true,
          isDesktop: false,
          caching: false,
          directoryBusy: false,
          onOpenDirectory: () {},
          onClearCache: () {},
          onMoveDirectory: () {},
          appVersion: '0.4.0',
          update: client,
          onOpenLink: opened.add,
        ),
      ),
    );
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    // 未注入架构且本机探测不到时，取 universal 兜底，仍只给一个按钮。
    expect(
      find.byKey(const ValueKey(
        'about-download-arknights_story_player-v0.5.0-android-universal.apk',
      )),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey(
        'about-download-arknights_story_player-v0.5.0-android-arm64-v8a.apk',
      )),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey(
      'about-download-arknights_story_player-v0.5.0-android-universal.apk',
    )));
    expect(opened.single, Uri.parse('https://example.com/universal.apk'));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('已是最新版本时提示且不展示安装包列表', (tester) async {
    final client = AppUpdateClient(
      client: _releaseClient(tag: 'v0.4.0'),
      currentVersion: '0.4.0',
    );
    addTearDown(client.close);
    await tester.pumpWidget(
      _host(
        SettingsPage(
          concurrency: 4,
          onConcurrencyChanged: (_) {},
          isMobile: false,
          isDesktop: true,
          caching: false,
          directoryBusy: false,
          onOpenDirectory: () {},
          onClearCache: () {},
          onMoveDirectory: () {},
          appVersion: '0.4.0',
          update: client,
        ),
      ),
    );
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('已是最新版本。'), findsOneWidget);
    expect(find.text('发现新版本'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('检查更新失败时显示错误信息', (tester) async {
    final client = AppUpdateClient(
      client: MockClient(
        (request) async => http.Response.bytes(utf8.encode('busy'), 503),
      ),
      currentVersion: '0.4.0',
    );
    addTearDown(client.close);
    await tester.pumpWidget(
      _host(
        SettingsPage(
          concurrency: 4,
          onConcurrencyChanged: (_) {},
          isMobile: false,
          isDesktop: true,
          caching: false,
          directoryBusy: false,
          onOpenDirectory: () {},
          onClearCache: () {},
          onMoveDirectory: () {},
          appVersion: '0.4.0',
          update: client,
        ),
      ),
    );
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('检查更新失败：更新服务返回 HTTP 503。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关于页链接通过 onOpenLink 打开', (tester) async {
    final opened = <Uri>[];
    final client = AppUpdateClient(currentVersion: '0.4.0');
    addTearDown(client.close);
    await tester.pumpWidget(
      _host(
        SettingsPage(
          concurrency: 4,
          onConcurrencyChanged: (_) {},
          isMobile: false,
          isDesktop: true,
          caching: false,
          directoryBusy: false,
          onOpenDirectory: () {},
          onClearCache: () {},
          onMoveDirectory: () {},
          update: client,
          onOpenLink: opened.add,
        ),
      ),
    );
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    for (final (label, expected) in [
      ('项目主页', AppUpdateLinks.project),
      ('问题反馈', AppUpdateLinks.issues),
      ('更新日志', AppUpdateLinks.releases),
    ]) {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();
      expect(opened.last, expected, reason: label);
    }
    expect(opened, hasLength(3));
  });

  testWidgets('未接入更新服务时关于页仍可打开', (tester) async {
    await tester.pumpWidget(
      _host(
        SettingsPage(
          concurrency: 4,
          onConcurrencyChanged: (_) {},
          isMobile: false,
          isDesktop: true,
          caching: false,
          directoryBusy: false,
          onOpenDirectory: () {},
          onClearCache: () {},
          onMoveDirectory: () {},
          appVersion: '0.4.0',
        ),
      ),
    );
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    expect(find.text('此构建未接入更新检查。'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    // 检查按钮禁用。
    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('about-check-update')),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
