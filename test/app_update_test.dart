import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arknights_story_player/app/app_update.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _releaseBody({
  String tag = 'v0.5.0',
  String body = '更新说明',
  List<Map<String, Object>> assets = const [],
}) => jsonEncode({
  'tag_name': tag,
  'name': tag,
  'body': body,
  'html_url':
      'https://github.com/horizonzzzz/arknights-story-player/releases/tag/$tag',
  'assets': assets,
});

/// 测试用文件后端：写入真实临时目录，便于验证落盘结果。
class _TestStore extends UpdateFileStore {
  _TestStore(this.directory);

  final Directory? directory;

  @override
  Future<String?> downloadDirectory() async => directory?.path;
}

final _asset = AppUpdateAsset(
  name: 'arknights_story_player-v0.5.0-windows-x64.zip',
  uri: Uri.parse('https://example.com/arknights_story_player-v0.5.0-windows-x64.zip'),
  bytes: 11,
);

void main() {
  group('compareVersions', () {
    test('按数字段比较并忽略 v 前缀、构建号与预发布后缀', () {
      expect(compareVersions('0.4.0', '0.5.0'), lessThan(0));
      expect(compareVersions('0.4.1', '0.4'), greaterThan(0));
      expect(compareVersions('v0.4.0+4', '0.4.0'), 0);
      expect(compareVersions('0.4.0-rc.1', '0.4.0'), 0);
      expect(compareVersions('0.10.0', '0.9.0'), greaterThan(0));
      expect(compareVersions('1.2.3', '1.2.3'), 0);
      // 无法解析的版本视为 0.0.0，而不是直接判等。
      expect(compareVersions('unknown', '0.4.0'), lessThan(0));
      expect(compareVersions('unknown', 'beta'), 0);
    });
  });

  group('AppUpdateClient.check', () {
    test('返回可用更新与全部资产', () async {
      final client = AppUpdateClient(
        client: MockClient(
          (request) async => http.Response.bytes(
            utf8.encode(
              _releaseBody(
                assets: [
                  {
                    'name':
                        'arknights_story_player-v0.5.0-windows-x64-setup.exe',
                    'browser_download_url': 'https://example.com/setup.exe',
                    'size': 2048,
                  },
                  {
                    'name': 'arknights_story_player-v0.5.0-android-universal.apk',
                    'browser_download_url':
                        'https://example.com/universal.apk',
                    'size': 4096,
                  },
                ],
              ),
            ),
            200,
          ),
        ),
        currentVersion: '0.4.0',
      );
      addTearDown(client.close);
      final update = await client.check();
      expect(update, isNotNull);
      expect(update!.version, 'v0.5.0');
      expect(update.notes, '更新说明');
      expect(
        update.pageUri.toString(),
        'https://github.com/horizonzzzz/arknights-story-player/releases/tag/v0.5.0',
      );
      expect(update.assets, hasLength(2));
      expect(
        update.assets.first.name,
        'arknights_story_player-v0.5.0-windows-x64-setup.exe',
      );
      expect(update.assets.first.bytes, 2048);
      expect(update.assets.first.uri.toString(), 'https://example.com/setup.exe');
    });

    test('远端不比当前新时返回 null', () async {
      for (final tag in ['v0.4.0', 'v0.3.9']) {
        final client = AppUpdateClient(
          client: MockClient(
            (request) async =>
                http.Response.bytes(utf8.encode(_releaseBody(tag: tag)), 200),
          ),
          currentVersion: '0.4.0',
        );
        addTearDown(client.close);
        expect(await client.check(), isNull, reason: tag);
      }
    });

    test('404 提示尚未发布任何版本', () async {
      final client = AppUpdateClient(
        client: MockClient((request) async => http.Response('', 404)),
        currentVersion: '0.4.0',
      );
      addTearDown(client.close);
      await expectLater(
        client.check(),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('尚未发布'),
          ),
        ),
      );
    });

    test('非 200 状态码带 HTTP 状态提示', () async {
      final client = AppUpdateClient(
        client: MockClient((request) async => http.Response('', 503)),
        currentVersion: '0.4.0',
      );
      addTearDown(client.close);
      await expectLater(
        client.check(),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('HTTP 503'),
          ),
        ),
      );
    });

    test('响应不是合法 JSON 时提示格式异常', () async {
      final client = AppUpdateClient(
        client: MockClient((request) async => http.Response('not-json', 200)),
        currentVersion: '0.4.0',
      );
      addTearDown(client.close);
      await expectLater(
        client.check(),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('格式异常'),
          ),
        ),
      );
    });

    test('缺少当前版本号时无法检查', () async {
      final client = AppUpdateClient(
        client: MockClient((request) async => http.Response('', 200)),
      );
      addTearDown(client.close);
      await expectLater(
        client.check(),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('版本号'),
          ),
        ),
      );
    });

    test('网络异常提示无法连接更新服务器', () async {
      final client = AppUpdateClient(
        client: MockClient(
          (request) async => throw http.ClientException('offline'),
        ),
        currentVersion: '0.4.0',
      );
      addTearDown(client.close);
      await expectLater(
        client.check(),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('无法连接'),
          ),
        ),
      );
    });

    test('请求携带 GitHub API 必需的 Accept 与 User-Agent 头', () async {
      http.Request? captured;
      final client = AppUpdateClient(
        client: MockClient((request) async {
          captured = request;
          return http.Response.bytes(
            utf8.encode(_releaseBody(tag: 'v0.4.0')),
            200,
          );
        }),
        currentVersion: '0.4.0',
      );
      addTearDown(client.close);
      await client.check();
      expect(captured, isNotNull);
      expect(captured!.headers['accept'], contains('vnd.github'));
      expect(captured!.headers['user-agent'], isNotEmpty);
    });
  });

  group('AppUpdateClient.download', () {
    Directory tempDirectory() {
      final directory = Directory.systemTemp.createTempSync('app-update-test');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      return directory;
    }

    test('流式写入下载目录并回报完成进度', () async {
      final directory = tempDirectory();
      final client = AppUpdateClient(
        client: MockClient.streaming(
          (request, bodyStream) async {
            return http.StreamedResponse(
              Stream.fromIterable([
                utf8.encode('hello '),
                utf8.encode('world'),
              ]),
              200,
              contentLength: 11,
            );
          },
        ),
        currentVersion: '0.4.0',
        files: _TestStore(directory),
      );
      addTearDown(client.close);
      final progress = <int>[];
      final path = await client.download(
        _asset,
        onProgress: (received, total) => progress.add(received),
      );
      expect(path, contains(directory.path));
      final file = File(path);
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), 'hello world');
      // 小于 256 KB 的下载只在完成时汇报一次进度。
      expect(progress, [11]);
      expect(
        directory.listSync().where((entry) => entry.path.endsWith('.part')),
        isEmpty,
      );
    });

    test('取消后抛 UpdateDownloadCancelled 并清理临时文件', () async {
      final directory = tempDirectory();
      final controller = StreamController<List<int>>();
      final client = AppUpdateClient(
        client: MockClient.streaming(
          (request, bodyStream) async {
            return http.StreamedResponse(
              controller.stream,
              200,
              contentLength: 10,
            );
          },
        ),
        currentVersion: '0.4.0',
        files: _TestStore(directory),
      );
      addTearDown(client.close);
      addTearDown(controller.close);
      var cancelled = false;
      final future = client.download(_asset, isCancelled: () => cancelled);
      await Future<void>.delayed(Duration.zero);
      controller.add(utf8.encode('chunk'));
      await Future<void>.delayed(Duration.zero);
      cancelled = true;
      controller.add(utf8.encode('chunk'));
      await expectLater(future, throwsA(isA<UpdateDownloadCancelled>()));
      expect(directory.listSync(), isEmpty);
    });

    test('HTTP 错误抛 AppUpdateException 且不残留文件', () async {
      final directory = tempDirectory();
      final client = AppUpdateClient(
        client: MockClient.streaming(
          (request, bodyStream) async {
            return http.StreamedResponse(Stream.empty(), 404);
          },
        ),
        currentVersion: '0.4.0',
        files: _TestStore(directory),
      );
      addTearDown(client.close);
      await expectLater(
        client.download(_asset),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('HTTP 404'),
          ),
        ),
      );
      expect(directory.listSync(), isEmpty);
    });

    test('没有可用下载目录时提示前往发布页', () async {
      final client = AppUpdateClient(
        client: MockClient.streaming(
          (request, bodyStream) async {
            return http.StreamedResponse(Stream.empty(), 200);
          },
        ),
        currentVersion: '0.4.0',
        files: _TestStore(null),
      );
      addTearDown(client.close);
      await expectLater(
        client.download(_asset),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('发布页'),
          ),
        ),
      );
    });
  });
}
