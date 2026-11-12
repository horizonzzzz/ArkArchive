import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arknights_story_player/app/app_update.dart';
import 'package:crypto/crypto.dart';
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
  'html_url': 'https://github.com/horizonzzzz/ArkArchive/releases/tag/$tag',
  'assets': assets,
});

/// 测试用文件后端：写入真实临时目录，便于验证落盘结果。
class _TestStore extends UpdateFileStore {
  _TestStore(this.directory);

  final Directory? directory;

  @override
  Future<String?> downloadDirectory() async => directory?.path;
}

class _FailingWriteStore extends _TestStore {
  _FailingWriteStore(super.directory);

  @override
  Future<void> write(String path, Stream<List<int>> stream) async {
    throw const FileSystemException('磁盘写入失败');
  }
}

final _asset = AppUpdateAsset(
  name: 'arknights_story_player-v0.5.0-windows-x64.zip',
  uri: Uri.parse(
    'https://example.com/arknights_story_player-v0.5.0-windows-x64.zip',
  ),
  bytes: 11,
);

/// 测试用临时目录；用后整体删除。
Directory _tempDirectory() {
  final directory = Directory.systemTemp.createTempSync('app-update-test');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}

/// Release Atom 订阅样例；备用检查通道的响应体。
String _atomFeed({String tag = 'v0.5.0', String? title, String prefix = ''}) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Recent releases</title>
  $prefix
  <entry>
    <title>${title ?? tag}</title>
    <link rel="alternate" href="https://github.com/horizonzzzz/ArkArchive/releases/tag/${Uri.encodeComponent(tag)}" />
    <content type="html">&lt;p&gt;修复若干问题。&lt;/p&gt;</content>
  </entry>
</feed>
''';

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
                    'name':
                        'arknights_story_player-v0.5.0-android-universal.apk',
                    'browser_download_url': 'https://example.com/universal.apk',
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
        'https://github.com/horizonzzzz/ArkArchive/releases/tag/v0.5.0',
      );
      expect(update.assets, hasLength(2));
      expect(
        update.assets.first.name,
        'arknights_story_player-v0.5.0-windows-x64-setup.exe',
      );
      expect(update.assets.first.bytes, 2048);
      expect(
        update.assets.first.uri.toString(),
        'https://example.com/setup.exe',
      );
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

  group('AppUpdateClient.check 备用通道', () {
    test('API 403 时改用 Release 订阅备用通道', () async {
      final requested = <Uri>[];
      final client = AppUpdateClient(
        client: MockClient((request) async {
          requested.add(request.url);
          if (request.url.host == 'api.github.com') {
            return http.Response('rate limited', 403);
          }
          return http.Response.bytes(utf8.encode(_atomFeed()), 200);
        }),
        currentVersion: '0.4.0',
      );
      addTearDown(client.close);
      final update = await client.check();
      expect(update, isNotNull);
      expect(update!.version, 'v0.5.0');
      // 订阅里的说明是 HTML，去除标签后展示。
      expect(update.notes, '修复若干问题。');
      expect(
        update.pageUri.toString(),
        'https://github.com/horizonzzzz/ArkArchive/releases/tag/v0.5.0',
      );
      // 下载链接按工作流产物命名约定构造。
      final names = update.assets.map((asset) => asset.name).toList();
      expect(
        names,
        contains('arknights_story_player-v0.5.0-android-universal.apk'),
      );
      expect(
        names,
        contains('arknights_story_player-v0.5.0-windows-x64-setup.exe'),
      );
      final universal = update.assets.singleWhere(
        (asset) => asset.name.contains('android-universal'),
      );
      expect(
        universal.uri.toString(),
        'https://github.com/horizonzzzz/ArkArchive/releases/download/'
        'v0.5.0/arknights_story_player-v0.5.0-android-universal.apk',
      );
      expect(requested.where((uri) => uri.host == 'github.com'), isNotEmpty);
    });

    test('备用通道使用发布链接并跳过非版本及其他仓库条目', () async {
      final feed = _atomFeed(
        tag: 'v0.5.0-rc.1+7',
        title: '新版发布说明',
        prefix: '''
          <entry><title>归档</title>
            <link href="https://github.com/horizonzzzz/ArkArchive/releases/tag/archive%2Ftts-2026-11" />
          </entry>
          <entry><title>v99.0.0</title>
            <link href="https://github.com/other/ArkArchive/releases/tag/v99.0.0" />
          </entry>
        ''',
      );
      final client = AppUpdateClient(
        client: MockClient(
          (request) async => request.url.host == 'api.github.com'
              ? http.Response('', 403)
              : http.Response.bytes(utf8.encode(feed), 200),
        ),
        currentVersion: '0.4.0',
      );
      addTearDown(client.close);
      final update = await client.check();
      expect(update!.version, 'v0.5.0-rc.1+7');
      expect(update.pageUri.path, endsWith('/v0.5.0-rc.1+7'));
      expect(update.assets.first.uri.path, contains('/v0.5.0-rc.1+7/'));
      expect(
        update.assets.first.name,
        'arknights_story_player-v0.5.0-rc.1-android-arm64-v8a.apk',
      );
      expect(update.notes, '修复若干问题。');
    });
    test('API 403 且备用通道也失败时合并提示', () async {
      final client = AppUpdateClient(
        client: MockClient((request) async => http.Response('', 403)),
        currentVersion: '0.4.0',
      );
      addTearDown(client.close);
      await expectLater(
        client.check(),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            allOf(contains('403'), contains('备用通道')),
          ),
        ),
      );
    });

    test('404 属于确定结论，不再请求备用通道', () async {
      final requested = <Uri>[];
      final client = AppUpdateClient(
        client: MockClient((request) async {
          requested.add(request.url);
          return http.Response('', 404);
        }),
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
      expect(requested, hasLength(1));
    });

    test('备用通道版本不比当前新时同样返回 null', () async {
      final client = AppUpdateClient(
        client: MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response('', 503);
          }
          return http.Response.bytes(
            utf8.encode(_atomFeed(tag: 'v0.4.0')),
            200,
          );
        }),
        currentVersion: '0.4.0',
      );
      addTearDown(client.close);
      expect(await client.check(), isNull);
    });

    test('资产的 digest 字段解析为 sha256', () async {
      final client = AppUpdateClient(
        client: MockClient(
          (request) async => http.Response.bytes(
            utf8.encode(
              _releaseBody(
                assets: [
                  {
                    'name': 'app-v0.5.0-android-arm64-v8a.apk',
                    'browser_download_url': 'https://example.com/app.apk',
                    'size': 3,
                    'digest': 'sha256:0123abcd',
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
      expect(update!.assets.single.sha256, '0123abcd');
    });
  });

  group('AppUpdateClient.download', () {
    test('流式写入下载目录并回报完成进度', () async {
      final directory = _tempDirectory();
      final client = AppUpdateClient(
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream.fromIterable([utf8.encode('hello '), utf8.encode('world')]),
            200,
            contentLength: 11,
          );
        }),
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
      final directory = _tempDirectory();
      final controller = StreamController<List<int>>();
      final client = AppUpdateClient(
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            controller.stream,
            200,
            contentLength: 10,
          );
        }),
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
      final directory = _tempDirectory();
      final client = AppUpdateClient(
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(Stream.empty(), 404);
        }),
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
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(Stream.empty(), 200);
        }),
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

  group('AppUpdateClient.download 多源回退', () {
    final githubAsset = AppUpdateAsset(
      name: 'arknights_story_player-v0.5.0-android-arm64-v8a.apk',
      uri: Uri.parse(
        'https://github.com/horizonzzzz/ArkArchive/releases/download/'
        'v0.5.0/arknights_story_player-v0.5.0-android-arm64-v8a.apk',
      ),
      sha256: sha256.convert(utf8.encode('installer')).toString(),
    );

    test('GitHub 资产先经加速代理，失败逐源回退到直连', () async {
      final directory = _tempDirectory();
      final requested = <Uri>[];
      final sources = <Uri>[];
      final client = AppUpdateClient(
        client: MockClient.streaming((request, bodyStream) async {
          requested.add(request.url);
          if (request.url.host == 'github.com') {
            return http.StreamedResponse(
              Stream.value(utf8.encode('installer')),
              200,
              contentLength: 9,
            );
          }
          return http.StreamedResponse(Stream.empty(), 500);
        }),
        currentVersion: '0.4.0',
        files: _TestStore(directory),
      );
      addTearDown(client.close);
      final path = await client.download(githubAsset, onSource: sources.add);
      expect(File(path).readAsStringSync(), 'installer');
      expect(requested.map((uri) => uri.host).toList(), [
        'gh-proxy.com',
        'ghproxy.net',
        'ghfast.top',
        'github.com',
      ]);
      expect(sources.map((uri) => uri.host).toList(), [
        'gh-proxy.com',
        'ghproxy.net',
        'ghfast.top',
        'github.com',
      ]);
    });

    test('缺少摘要时绕过第三方代理，直接从 GitHub 下载', () async {
      final directory = _tempDirectory();
      final requested = <Uri>[];
      final client = AppUpdateClient(
        client: MockClient.streaming((request, _) async {
          requested.add(request.url);
          return http.StreamedResponse(
            Stream.value(utf8.encode('installer')),
            200,
          );
        }),
        files: _TestStore(directory),
      );
      addTearDown(client.close);
      final asset = AppUpdateAsset(
        name: githubAsset.name,
        uri: githubAsset.uri,
      );
      final path = await client.download(asset);
      expect(requested, [githubAsset.uri]);
      expect(File(path).readAsStringSync(), 'installer');
    });

    test('连接超时、连接失败和响应流中断后依次换源', () async {
      final directory = _tempDirectory();
      final hosts = <String>[];
      final client = AppUpdateClient(
        client: MockClient.streaming((request, _) async {
          hosts.add(request.url.host);
          switch (request.url.host) {
            case 'gh-proxy.com':
              throw TimeoutException('connection timeout');
            case 'ghproxy.net':
              throw const SocketException('connection refused');
            case 'ghfast.top':
              return http.StreamedResponse(() async* {
                yield utf8.encode('stale');
                throw http.ClientException('connection reset');
              }(), 200);
            default:
              return http.StreamedResponse(
                Stream.value(utf8.encode('installer')),
                200,
              );
          }
        }),
        files: _TestStore(directory),
      );
      addTearDown(client.close);
      final path = await client.download(githubAsset);
      expect(hosts, [
        'gh-proxy.com',
        'ghproxy.net',
        'ghfast.top',
        'github.com',
      ]);
      expect(File(path).readAsStringSync(), 'installer');
      expect(
        directory.listSync().where((file) => file.path.endsWith('.part')),
        isEmpty,
      );
    });

    test('本地写入异常不会误判为换源', () async {
      final directory = _tempDirectory();
      var requests = 0;
      final client = AppUpdateClient(
        client: MockClient.streaming((request, _) async {
          requests++;
          return http.StreamedResponse(
            Stream.value(utf8.encode('installer')),
            200,
          );
        }),
        files: _FailingWriteStore(directory),
      );
      addTearDown(client.close);
      await expectLater(
        client.download(githubAsset),
        throwsA(isA<FileSystemException>()),
      );
      expect(requests, 1);
    });
    test('非 GitHub 地址单源直连', () async {
      final directory = _tempDirectory();
      final requested = <Uri>[];
      final sources = <Uri>[];
      final client = AppUpdateClient(
        client: MockClient.streaming((request, bodyStream) async {
          requested.add(request.url);
          return http.StreamedResponse(
            Stream.value(utf8.encode('installer')),
            200,
            contentLength: 9,
          );
        }),
        currentVersion: '0.4.0',
        files: _TestStore(directory),
      );
      addTearDown(client.close);
      await client.download(_asset, onSource: sources.add);
      expect(requested, [
        Uri.parse(
          'https://example.com/arknights_story_player-v0.5.0-windows-x64.zip',
        ),
      ]);
      expect(sources, requested);
    });

    test('sha256 不一致时换源重试，一致后才落盘', () async {
      final directory = _tempDirectory();
      final digest = sha256.convert(utf8.encode('installer')).toString();
      final asset = AppUpdateAsset(
        name: githubAsset.name,
        uri: githubAsset.uri,
        sha256: digest,
      );
      var attempt = 0;
      final client = AppUpdateClient(
        client: MockClient.streaming((request, bodyStream) async {
          attempt++;
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(attempt == 1 ? 'tampered!!' : 'installer'),
            ),
            200,
            contentLength: attempt == 1 ? 10 : 9,
          );
        }),
        currentVersion: '0.4.0',
        files: _TestStore(directory),
      );
      addTearDown(client.close);
      final path = await client.download(asset);
      expect(attempt, 2);
      expect(File(path).readAsStringSync(), 'installer');
    });

    test('所有源都校验失败时抛合并错误并清理临时文件', () async {
      final directory = _tempDirectory();
      final asset = AppUpdateAsset(
        name: githubAsset.name,
        uri: githubAsset.uri,
        sha256: 'deadbeef',
      );
      final client = AppUpdateClient(
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream.value(utf8.encode('wrong')),
            200,
            contentLength: 5,
          );
        }),
        currentVersion: '0.4.0',
        files: _TestStore(directory),
      );
      addTearDown(client.close);
      await expectLater(
        client.download(asset),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('所有下载源'),
          ),
        ),
      );
      expect(directory.listSync(), isEmpty);
    });

    test('空闲超时判失败并自动换源', () async {
      final directory = _tempDirectory();
      final stalled = StreamController<List<int>>();
      addTearDown(stalled.close);
      final client = AppUpdateClient(
        client: MockClient.streaming((request, bodyStream) async {
          if (request.url.host == 'gh-proxy.com') {
            return http.StreamedResponse(
              stalled.stream,
              200,
              contentLength: 10,
            );
          }
          return http.StreamedResponse(
            Stream.value(utf8.encode('installer')),
            200,
            contentLength: 9,
          );
        }),
        currentVersion: '0.4.0',
        files: _TestStore(directory),
        idleTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(client.close);
      final path = await client.download(githubAsset);
      expect(File(path).readAsStringSync(), 'installer');
    });
  });
}
