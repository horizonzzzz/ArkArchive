import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/data/file_cache.dart';
import 'package:arknights_story_player/story_player/data/cache_control.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/data/story_repository.dart';
import 'package:arknights_story_player/story_player/script.dart';

class MemoryCache extends FileCache {
  final Map<Uri, Uint8List> data = {};
  @override
  Future<void> clear({Set<Uri> keep = const {}}) async {
    data.removeWhere((uri, _) => !keep.contains(uri));
  }

  @override
  Future<void> delete(Uri uri) async {
    data.remove(uri);
  }

  @override
  Future<int> size() async =>
      data.values.fold<int>(0, (sum, bytes) => sum + bytes.length);
  @override
  Future<String?> location() async => null;
  @override
  Future<Uint8List?> read(Uri uri) async => data[uri];
  @override
  Future<void> write(Uri uri, Uint8List bytes) async {
    data[uri] = bytes;
  }

  @override
  Future<Uri> playableUri(Uri uri) async => uri;
}

class AbortAwareClient extends http.BaseClient {
  final started = Completer<void>();
  bool aborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    started.complete();
    await (request as http.AbortableRequest).abortTrigger;
    aborted = true;
    throw http.RequestAbortedException(request.url);
  }
}

class FailingCache extends MemoryCache {
  @override
  Future<void> write(Uri uri, Uint8List bytes) async =>
      throw StateError('磁盘已满');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('暂停等待当前资源结束，恢复后继续，删除时唤醒等待任务', () async {
    final firstStarted = Completer<void>();
    final firstResponse = Completer<http.Response>();
    final control = CacheControl();
    var requests = 0;
    final store = AssetStore(
      cache: MemoryCache(),
      client: MockClient((_) async {
        requests++;
        if (requests == 1) {
          firstStarted.complete();
          return firstResponse.future;
        }
        return http.Response('ok', 200);
      }),
    );
    addTearDown(store.close);
    final operation = store.runCacheDownload(
      () => store.preload({
        Uri.parse('https://example.test/one.txt'),
        Uri.parse('https://example.test/two.txt'),
      }),
      control: control,
    );
    await firstStarted.future;
    control.pause();
    firstResponse.complete(http.Response('ok', 200));
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    control.resume();
    expect(await operation, isEmpty);
    expect(requests, 2);
    control.pause();
    final waiting = control.checkpoint();
    control.cancel();
    await expectLater(waiting, throwsA(isA<CacheCancelled>()));
  });
  test('并发上限为一时，暂停的剧情不阻塞其他剧情', () async {
    final store = AssetStore(
      cache: MemoryCache(),
      client: MockClient((_) async => http.Response('ok', 200)),
    )..concurrency = 1;
    addTearDown(store.close);
    final paused = CacheControl()..pause();
    final active = CacheControl();
    final first = store.runCacheDownload(
      () => store.preload({Uri.parse('https://example.test/first.txt')}),
      control: paused,
    );
    final second = store.runCacheDownload(
      () => store.preload({Uri.parse('https://example.test/second.txt')}),
      control: active,
    );
    expect(await second, isEmpty);
    paused.resume();
    expect(await first, isEmpty);
  });
  test('移动端仅 Wi-Fi 设置阻止蜂窝网络缓存，不影响普通播放请求', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const methods = MethodChannel('dev.fluttercommunity.plus/connectivity');
    const events = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(
      methods,
      (call) async => <String>['mobile'],
    );
    messenger.setMockMethodCallHandler(events, (call) async => null);
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    var requests = 0;
    final cache = MemoryCache();
    final store = AssetStore(
      cache: cache,
      client: MockClient((_) async {
        requests++;
        return http.Response('ok', 200);
      }),
    );
    addTearDown(store.close);
    await store.setWifiOnly(true);
    final uri = Uri.parse('https://example.test/blocked.txt');
    await expectLater(
      store.runCacheDownload(() => store.load(uri)),
      throwsA(isA<WifiRequired>()),
    );
    await expectLater(
      store.runCacheDownload(() => store.preload({uri})),
      throwsA(isA<WifiRequired>()),
    );
    expect(requests, 0);
    await store.load(uri);
    expect(requests, 1);
    final restored = AssetStore(cache: cache);
    addTearDown(restored.close);
    await restored.loadSettings();
    expect(restored.wifiOnly, isTrue);
  });
  test('移动端切离 Wi-Fi 时中止正在进行的缓存请求', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const methods = MethodChannel('dev.fluttercommunity.plus/connectivity');
    const events = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(methods, (_) async => <String>['wifi']);
    messenger.setMockMethodCallHandler(events, (_) async => null);
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    final client = AbortAwareClient();
    final store = AssetStore(cache: MemoryCache(), client: client);
    addTearDown(store.close);
    await store.setWifiOnly(true);
    final operation = store.runCacheDownload(
      () => store.preload({Uri.parse('https://example.test/switch.txt')}),
    );
    final failure = expectLater(operation, throwsA(isA<WifiRequired>()));
    await client.started.future;
    await messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(<String>['mobile']),
      null,
    );
    await failure;
    expect(client.aborted, isTrue);
  });
  test('蜂窝网络缓存不复用普通播放的在途请求', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const methods = MethodChannel('dev.fluttercommunity.plus/connectivity');
    const events = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(
      methods,
      (_) async => <String>['mobile'],
    );
    messenger.setMockMethodCallHandler(events, (_) async => null);
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final started = Completer<void>();
    final response = Completer<http.Response>();
    var requests = 0;
    final store = AssetStore(
      cache: MemoryCache(),
      client: MockClient((_) {
        requests++;
        started.complete();
        return response.future;
      }),
    );
    addTearDown(store.close);
    await store.setWifiOnly(true);
    final uri = Uri.parse('https://example.test/shared.txt');
    final playback = store.load(uri);
    await started.future;
    await expectLater(
      store.runCacheDownload(() => store.load(uri)),
      throwsA(isA<WifiRequired>()),
    );
    response.complete(http.Response('ok', 200));
    expect(utf8.decode(await playback), 'ok');
    expect(requests, 1);
  });
  test('立绘按 body/index 选择差分并定位 face_overlay，保留路径层级和美元符', () {
    final catalog = MediaCatalog(
      variables: {'music': 'Sound_Beta_2/Music/Test/loop'},
      backgroundPpu: {},
      characters: {
        'actor': {
          'pos': {'x': 30, 'y': 150},
          'size': {'x': 1000, 'y': 1000},
          'groups': [
            {
              'mode': 'face_overlay',
              'base': r'actor/actor$1',
              'faceRect': {'x': 460, 'y': 87, 'w': 115, 'h': 82},
            },
          ],
          'array': [
            {
              'name': r'1$1',
              'alias': '',
              'group': 0,
              'face': r'actor/1$1',
              'body': 0,
              'index': 0,
            },
            {
              'name': r'2$1',
              'alias': '',
              'group': 0,
              'face': r'actor/2$1',
              'body': 0,
              'index': 1,
            },
          ],
        },
      },
    );
    final art = catalog.character(r'actor#2$1')!;
    expect(art.body.toString(), contains('actor/actor%241.png'));
    expect(art.face.toString(), contains('actor/2%241.png'));
    expect(art.faceRect!.left, 460);
    expect(art.size.width, 1000);
    expect(
      catalog.audio(r'$music').toString(),
      'https://torappu.prts.wiki/assets/audio/music/test/loop.mp3',
    );
    expect(catalog.character(r'actor#99$1'), isNull);
    final warnings = <String>[];
    final dependencies = catalog.dependencies(
      StoryScript.parse(
        r'[charslot(slot="m",name="actor#2$1")]'
        '\n'
        r'[Blocker(style="slider",fadetime=0.5)]',
      ),
      warnings,
    );
    expect(dependencies, hasLength(2));
    expect(
      dependencies.any((u) => u.path.endsWith('.png') && u.host.isNotEmpty),
      isTrue,
    );
    expect(warnings, isEmpty);
  });

  test('立绘键忽略大小写和脚本末尾空白，素材路径保留原始大小写', () {
    final catalog = MediaCatalog(
      variables: {},
      backgroundPpu: {},
      characters: {
        'char_1507_Mephisto_1': {
          'pos': {'x': 0, 'y': 0},
          'size': {'x': 100, 'y': 100},
          'array': [
            {
              'group': -1,
              'image': 'char_1507_Mephisto_1/char_1507_Mephisto_6',
              'body': 0,
              'index': 5,
            },
          ],
        },
      },
    );
    final art = catalog.character(' CHAR_1507_MEPHISTO_1#6 ');
    expect(
      art?.body.path,
      endsWith('/char_1507_Mephisto_1/char_1507_Mephisto_6.png'),
    );
  });
  test('预加载合并重复请求，换实例断网仍可读取缓存；失败项可以重试', () async {
    final cache = MemoryCache();
    var calls = 0;
    final uri = Uri.parse('https://example.test/image.png');
    final store = AssetStore(
      cache: cache,
      client: MockClient((_) async {
        calls++;
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );
    addTearDown(store.close);
    await Future.wait([store.load(uri), store.load(uri)]);
    expect(calls, 1);
    final offline = AssetStore(
      cache: cache,
      client: MockClient((_) async => throw StateError('离线')),
    );
    addTearDown(offline.close);
    expect(await offline.load(uri), [1, 2, 3]);
    var fail = true;
    final retry = AssetStore(
      cache: cache,
      client: MockClient(
        (_) async => http.Response.bytes([4], fail ? 404 : 200),
      ),
    );
    addTearDown(retry.close);
    final other = Uri.parse('https://example.test/missing.mp3');
    expect(await retry.preload({other}), hasLength(1));
    fail = false;
    expect(await retry.load(other), [4]);
  });

  test('并发上限与设置持久化生效，临时网络错误自动重试', () async {
    final cache = MemoryCache();
    var active = 0;
    var maximum = 0;
    final attempts = <Uri, int>{};
    final store = AssetStore(
      cache: cache,
      client: MockClient((request) async {
        active++;
        if (active > maximum) maximum = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        final count = attempts.update(
          request.url,
          (n) => n + 1,
          ifAbsent: () => 1,
        );
        return http.Response.bytes([1], count == 1 ? 503 : 200);
      }),
    );
    addTearDown(store.close);
    await store.setConcurrency(2);
    final restored = AssetStore(cache: cache);
    addTearDown(restored.close);
    await restored.loadSettings();
    expect(restored.concurrency, 2);
    final urls = List.generate(
      5,
      (i) => Uri.parse('https://example.test/$i'),
    ).toSet();
    expect(await store.preload(urls), isEmpty);
    expect(maximum, lessThanOrEqualTo(2));
    expect(attempts.values, everyElement(2));
  });

  test('拒绝把错误页面作为素材缓存', () async {
    final cache = MemoryCache();
    final uri = Uri.parse('https://example.test/image.png');
    final store = AssetStore(
      cache: cache,
      client: MockClient(
        (_) async => http.Response(
          '<html>error</html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
      ),
    );
    addTearDown(store.close);
    expect(await store.preload({uri}), hasLength(1));
    expect(cache.data[uri], isNull);
  });
  test('写入失败不影响当前播放，但不能报告已离线', () async {
    final store = AssetStore(
      cache: FailingCache(),
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    addTearDown(store.close);
    final uri = Uri.parse('https://example.test/file');
    expect(await store.load(uri), [1]);
    expect(await store.preload({uri}), hasLength(1));
  });
  test('完整剧情缓存可在新实例断网后读取，失败不登记', () async {
    final cache = MemoryCache();
    final entry = StoryEntry('测试', 'test/story');
    var fail = false;
    final store = AssetStore(
      cache: cache,
      client: MockClient((request) async {
        if (fail && request.url.path.endsWith('story.txt')) {
          return http.Response('missing', 404);
        }
        if (request.url.path.endsWith('story.txt')) {
          return http.Response.bytes(utf8.encode('[name="甲"]对白'), 200);
        }
        return http.Response('{}', 200);
      }),
    );
    addTearDown(store.close);
    final repository = StoryRepository(store);
    expect(await repository.cacheEntry(entry), isEmpty);
    expect(await repository.cachedStories(), contains(entry.path));
    final offline = AssetStore(
      cache: cache,
      client: MockClient((_) async => throw http.ClientException('离线')),
    );
    addTearDown(offline.close);
    final offlineRepository = StoryRepository(offline);
    expect(await offlineRepository.loadIndex(), isEmpty);
    final document = await offlineRepository.loadEntry(entry);
    expect(document.script.commands.single.text, '对白');
    expect((await offlineRepository.prepare(document)).warnings, isEmpty);
    fail = true;
    final missing = StoryEntry('缺失', 'test/missing/story');
    await expectLater(
      repository.cacheEntry(missing),
      throwsA(isA<http.ClientException>()),
    );
    expect(await repository.cachedStories(), isNot(contains(missing.path)));
  });
  test('删除单幕只回收独占素材，保留其他离线剧情共用资源', () async {
    final cache = MemoryCache();
    final store = AssetStore(
      cache: cache,
      client: MockClient((request) async {
        if (request.url.path.endsWith('.txt')) {
          final unique = request.url.path.contains('first')
              ? 'first'
              : 'second';
          return http.Response.bytes(
            utf8.encode(
              '[name="甲"]对白\n[background(image="shared")]\n[background(image="$unique")]',
            ),
            200,
          );
        }
        if (request.url.path.endsWith('.png')) {
          return http.Response.bytes([1, 2], 200);
        }
        return http.Response('{}', 200);
      }),
    );
    addTearDown(store.close);
    final repo = StoryRepository(store);
    const first = StoryEntry('第一幕', 'test/first');
    const second = StoryEntry('第二幕', 'test/second');
    for (final errors in await Future.wait([
      repo.cacheEntry(first),
      repo.cacheEntry(second),
    ])) {
      expect(errors, isEmpty);
    }
    final shared = Uri.parse(
      'https://torappu.prts.wiki/assets/avg/background/shared.png',
    );
    final firstOnly = Uri.parse(
      'https://torappu.prts.wiki/assets/avg/background/first.png',
    );
    final secondOnly = Uri.parse(
      'https://torappu.prts.wiki/assets/avg/background/second.png',
    );
    expect(await repo.deleteCachedStory(first), isTrue);
    expect(cache.data[shared], isNotNull);
    expect(cache.data[firstOnly], isNull);
    expect(cache.data[secondOnly], isNotNull);
    expect(await repo.cachedStories(), {second.path});
  });
  test('旧版离线记录缺少素材清单时不删除任何素材', () async {
    final cache = MemoryCache();
    final store = AssetStore(
      cache: cache,
      client: MockClient((request) async {
        if (request.url.path.endsWith('.txt')) {
          return http.Response.bytes(
            utf8.encode('[name="甲"]对白\n[background(image="shared")]'),
            200,
          );
        }
        if (request.url.path.endsWith('.png')) {
          return http.Response.bytes([1, 2], 200);
        }
        return http.Response('{}', 200);
      }),
    );
    addTearDown(store.close);
    final repository = StoryRepository(store);
    const entry = StoryEntry('新剧情', 'test/new');
    expect(await repository.cacheEntry(entry), isEmpty);
    final index = Uri.parse('https://local.invalid/offline-stories-v1');
    cache.data[index] = Uint8List.fromList(
      utf8.encode(jsonEncode([entry.path, 'test/old'])),
    );
    final shared = Uri.parse(
      'https://torappu.prts.wiki/assets/avg/background/shared.png',
    );
    expect(await repository.deleteCachedStory(entry), isFalse);
    expect(cache.data[shared], isNotNull);
    expect(await repository.cachedStories(), {'test/old'});
  });
  test(
    'PRTS HTML 从 datas_txt 提取脚本；索引使用实际 storyTxt 且不按 storyCanShow 过滤',
    () async {
      final store = AssetStore(
        cache: MemoryCache(),
        client: MockClient((r) async {
          if (r.url.host == 'prts.wiki') {
            return http.Response(
              '<h1 id="firstHeading">测试剧情</h1><pre id="datas_txt">[name="甲"]对白</pre>',
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'chapter': {
                'name': '测试章节',
                'entryType': 'MAINLINE',
                'infoUnlockDatas': [
                  {
                    'storyCode': 'TEST',
                    'storyName': '测试',
                    'avgTag': '行动前',
                    'storyTxt': 'obt/test/story',
                    'storyCanShow': 1,
                  },
                  {
                    'storyCode': 'HIDDEN',
                    'storyName': '隐藏',
                    'storyTxt': 'obt/test/hidden',
                    'storyCanShow': 0,
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(store.close);
      final repository = StoryRepository(store);
      final story = await repository.load(
        Uri.parse('https://prts.wiki/w/Test/END'),
      );
      expect(story.title, '测试剧情');
      expect(story.script.commands.single.text, '对白');
      final groups = await repository.loadIndex();
      expect(groups.single.name, '测试章节');
      // storyCanShow=0 的主线与干员密录同样进目录，否则整类剧情会被滤掉。
      expect(groups.single.entries.map((e) => e.path), [
        'obt/test/story',
        'obt/test/hidden',
      ]);
      expect(groups.single.entries.first.title, 'TEST 测试 行动前');
      expect(groups.single.entryType, 'MAINLINE');
      expect(groups.single.entries.first.code, 'TEST');
      expect(groups.single.entries.first.name, '测试');
      expect(groups.single.entries.first.tag, '行动前');
      expect(const StoryGroup('旧调用', []).entryType, 'NONE');
      expect(const StoryEntry('旧标题', 'old/path').name, isEmpty);
    },
  );

  test('字体与滑动遮罩随应用打包，运行时不下载', () async {
    final font = await rootBundle.load(MediaCatalog.fontAsset);
    expect(font.lengthInBytes, greaterThan(1000000));
    // FontLoader 只接受 SFNT 容器，WOFF2 不会让字体真正生效。
    expect(String.fromCharCodes(font.buffer.asUint8List(0, 4)), isNot('wOF2'));
    expect(
      (await rootBundle.load(MediaCatalog.slideMaskAsset)).lengthInBytes,
      greaterThan(0),
    );
  });
  test('图片遮罩和数值枚举 avgdisplay 进入静态依赖，重复 URL 去重', () {
    final catalog = MediaCatalog(
      variables: {},
      characters: {},
      backgroundPpu: {},
    );
    final dependencies = catalog.dependencies(
      StoryScript.parse('''
[blocker(image="mask",a=1)]
[cgitem(image="mask")]
[avgdisplay(style=5,slot=1,name="snow")]
[avgdisplay(style="bg",slot="bgover",name="snow")]
[avgdisplay(style=3,slot=1,name="unsupported")]
'''),
      [],
    );
    expect(dependencies, {
      catalog.image('mask', cg: true),
      catalog.image('snow'),
    });
  });
}
