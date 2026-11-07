import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/data/file_cache.dart';
import 'package:arknights_story_player/story_player/data/cache_control.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/data/story_repository.dart';
import 'package:arknights_story_player/story_player/data/playback_settings.dart';
import 'package:arknights_story_player/story_player/data/playback_progress.dart';
import 'package:arknights_story_player/story_player/runtime/playback_checkpoint.dart';
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
  var requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (++requests > 1) return http.StreamedResponse(Stream.value([1, 2]), 200);
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

  test('多篇剧情分别保存，完成一篇不影响其他断点，清理资源后均可恢复', () async {
    final cache = MemoryCache();
    final store = AssetStore(cache: cache);
    final restored = AssetStore(cache: cache);
    addTearDown(store.close);
    addTearDown(restored.close);
    final script = StoryScript.parse('第一句\n第二句');
    PlaybackProgress progress(String path, int cursor) => PlaybackProgress(
      path: path,
      scriptHash: PlaybackProgress.fingerprint(script),
      checkpoint: PlaybackCheckpoint(cursor: cursor, trace: [0]),
    );
    await store.setPlaybackProgress(progress('main/0-1', 1));
    await store.setPlaybackProgress(progress('activity/1-1', 2));
    expect(store.playbackProgresses, hasLength(2));
    await store.removePlaybackProgress('main/0-1');
    expect(store.getPlaybackProgress('main/0-1'), isNull);
    expect(store.getPlaybackProgress('activity/1-1')!.checkpoint.cursor, 2);
    await store.clearCache();
    await restored.loadSettings();
    expect(restored.playbackProgresses, hasLength(1));
    expect(restored.getPlaybackProgress('activity/1-1')!.checkpoint.cursor, 2);
  });

  test('迁移旧版单篇断点格式且保留原进度', () async {
    final cache = MemoryCache();
    final script = StoryScript.parse('正文');
    final old = PlaybackProgress(
      path: 'main/0-1',
      scriptHash: PlaybackProgress.fingerprint(script),
      checkpoint: PlaybackCheckpoint(cursor: 1, trace: [0]),
    );
    await cache.write(
      Uri.parse('https://local.invalid/story-playback-progress-v1'),
      Uint8List.fromList(utf8.encode(jsonEncode(old.toJson()))),
    );
    final store = AssetStore(cache: cache);
    addTearDown(store.close);
    await store.loadSettings();
    expect(store.getPlaybackProgress('main/0-1')!.toJson(), old.toJson());
    await store.setPlaybackProgress(
      PlaybackProgress(
        path: 'activity/1-1',
        scriptHash: old.scriptHash,
        checkpoint: PlaybackCheckpoint(cursor: 1, trace: [0]),
      ),
    );
    await store.loadSettings();
    expect(store.playbackProgresses, hasLength(2));
  });

  test('损坏记录不影响加载，保存失败不宣称已保存', () async {
    final cache = MemoryCache();
    await cache.write(
      Uri.parse('https://local.invalid/story-playback-progress-v1'),
      Uint8List.fromList(utf8.encode('{invalid')),
    );
    final store = AssetStore(cache: cache);
    final failing = AssetStore(cache: FailingCache());
    addTearDown(store.close);
    addTearDown(failing.close);
    await store.loadSettings();
    expect(store.playbackProgresses, isEmpty);
    final script = StoryScript.parse('正文');
    await expectLater(
      failing.setPlaybackProgress(
        PlaybackProgress(
          path: 'main/0-1',
          scriptHash: PlaybackProgress.fingerprint(script),
          checkpoint: PlaybackCheckpoint(cursor: 1, trace: [0]),
        ),
      ),
      throwsStateError,
    );
    expect(failing.playbackProgresses, isEmpty);
  });

  test('播放设置保存、清理缓存后保留并恢复', () async {
    final cache = MemoryCache();
    final store = AssetStore(cache: cache);
    final restored = AssetStore(cache: cache);
    addTearDown(store.close);
    addTearDown(restored.close);
    await store.setPlaybackSettings(
      const PlaybackSettings(
        master: .3,
        bgm: .4,
        sfx: .5,
        autoDelay: 3,
        typingMs: 60,
      ),
    );
    await store.clearCache();
    await restored.loadSettings();
    expect(restored.playbackSettings.toJson(), {
      'master': .3,
      'bgm': .4,
      'sfx': .5,
      'autoDelay': 3.0,
      'typingMs': 60.0,
    });
  });

  test('节点诊断绕过缓存并检查响应状态', () async {
    var calls = 0;
    final store = AssetStore(
      cache: MemoryCache(),
      client: MockClient((request) async {
        calls++;
        return http.Response('', request.url.path == '/ok' ? 200 : 503);
      }),
    );
    addTearDown(store.close);
    expect(await store.probe(Uri.parse('https://example.test/ok')), isTrue);
    expect(await store.probe(Uri.parse('https://example.test/fail')), isFalse);
    expect(calls, 2);
  });
  test('暂停丢弃已中断资源结果，恢复后继续，删除时唤醒等待任务', () async {
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
    expect(requests, 3);
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
  test('暂停立即中止素材请求，取消后不继续请求', () async {
    final client = AbortAwareClient();
    final store = AssetStore(cache: MemoryCache(), client: client);
    addTearDown(store.close);
    final control = CacheControl();
    final operation = store.runCacheDownload(
      () => store.preload({Uri.parse('https://example.test/abort.txt')}),
      control: control,
    );
    await client.started.future;
    control.pause();
    await Future<void>.delayed(Duration.zero);
    expect(client.aborted, isTrue);
    final failure = expectLater(operation, throwsA(isA<CacheCancelled>()));
    control.cancel();
    await failure;
  });

  test('降档中断请求后恢复可成功，已完成素材不重下', () async {
    final client = AbortAwareClient();
    final cache = MemoryCache();
    final store = AssetStore(cache: cache, client: client);
    addTearDown(store.close);
    final uri = Uri.parse('https://example.test/resume.mp3');
    final control = CacheControl();
    final operation = store.runCacheDownload(
      () => store.preload({uri}),
      control: control,
    );
    await client.started.future;
    control.setScheduled(false);
    await Future<void>.delayed(Duration.zero);
    expect(client.aborted, isTrue);
    expect(cache.data[uri], isNull);
    control.setScheduled(true);
    expect(await operation, isEmpty);
    expect(cache.data[uri], [1, 2]);
    expect(client.requests, 2);
    expect(
      await store.runCacheDownload(
        () => store.preload({uri}),
        control: control,
      ),
      isEmpty,
    );
    expect(client.requests, 2);
  });

  test('同一资源的不同剧情请求不会因其中一个暂停一起挂起', () async {
    final client = AbortAwareClient();
    final store = AssetStore(cache: MemoryCache(), client: client);
    addTearDown(store.close);
    final uri = Uri.parse('https://example.test/shared.mp3');
    final first = CacheControl();
    final second = CacheControl();
    final pending = store.runCacheDownload(
      () => store.preload({uri}),
      control: first,
    );
    await client.started.future;
    first.pause();
    expect(
      await store.runCacheDownload(() => store.preload({uri}), control: second),
      isEmpty,
    );
    final cancelled = expectLater(pending, throwsA(isA<CacheCancelled>()));
    first.cancel();
    await cancelled;
    expect(second.cancelled, isFalse);
  });
  test('手动暂停与并发限流独立，取消会唤醒所有等待', () async {
    final control = CacheControl()
      ..pause()
      ..setScheduled(false);
    var finished = false;
    final waiting = control.checkpoint().then((_) => finished = true);
    control.setScheduled(true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    control.resume();
    await waiting;
    expect(finished, isTrue);
    control.setScheduled(false);
    final cancelled = expectLater(
      control.checkpoint(),
      throwsA(isA<CacheCancelled>()),
    );
    control.cancel();
    await cancelled;
  });

  test('音频查找忽略大小写，但不改变剧情文本变量表', () {
    final catalog = MediaCatalog(
      variables: {
        'SomeText': '保持原名',
        'MusicKey': '@audio/a.mp3',
        'musickey': '@audio/b.mp3',
      },
      characters: {},
      backgroundPpu: {},
    );
    expect(catalog.variables['SomeText'], '保持原名');
    expect(catalog.audio(r'$MusicKey')!.path, '/assets/audio/a.mp3');
    expect(catalog.audio(r'$musickey')!.path, '/assets/audio/b.mp3');
    expect(catalog.audio(r'$MUSICKEY')!.path, '/assets/audio/b.mp3');
  });
  test('混合大小写和首尾空白的音频变量全部解析，未知变量仍报错', () {
    final variables = {
      'd_avg_OriginiumArts_soundwave':
          'Sound_Beta_2/AVG/d_avg_OriginiumArts_soundwave',
      'd_avg_OriginiumArts_fire_long':
          'Sound_Beta_2/AVG/d_avg_OriginiumArts_fire_long',
      'd_avg_OriginiumArts_heart_1':
          'Sound_Beta_2/AVG/d_avg_OriginiumArts_heart_1',
      'ReunionNormal_loop': 'Sound_Beta_2/Music/AVG/m_avg_ReunionNormal_loop',
      'ReunionNormal_intro': 'Sound_Beta_2/Music/AVG/m_avg_ReunionNormal_intro',
      'm_sys_act51sideInstrumental_loop':
          'Sound_Beta_2/Music/AVG/m_sys_act51sideInstrumental_loop',
      'd_avg_Qinggong': 'Sound_Beta_2/AVG/d_avg_Qinggong',
      'd_avg_OriginiumArts_fire_short':
          'Sound_Beta_2/AVG/d_avg_OriginiumArts_fire_short',
      'd_avg_Warlockarrow': 'Sound_Beta_2/AVG/d_avg_Warlockarrow',
    };
    final catalog = MediaCatalog(
      variables: variables,
      characters: {},
      backgroundPpu: {},
    );
    for (final entry in variables.entries) {
      final expected =
          'https://torappu.prts.wiki/assets/audio/${entry.value.toLowerCase().substring(13)}.mp3';
      expect(catalog.audio(' \$${entry.key} ').toString(), expected);
      expect(
        catalog.audio('\$${entry.key.toUpperCase()}').toString(),
        expected,
      );
    }
    final warnings = <String>[];
    final script = StoryScript.parse(
      variables.keys.map((key) => '[PlaySound(key="\$$key")]').join('\n'),
    );
    expect(catalog.dependencies(script, warnings), hasLength(9));
    expect(warnings, isEmpty);
    catalog.dependencies(
      StoryScript.parse(r'[PlaySound(key="$missing")]'),
      warnings,
    );
    expect(warnings.single, contains('未解析音频'));
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
        r'[interlude(maskid="group_interclude_square_common",channel=3)]'
        '\n'
        r'[interlude(channel=3,type=3,name="avg_4223_botany_1#1$1")]'
        '\n'
        r'[Blocker(style="slider",fadetime=0.5)]',
      ),
      warnings,
    );
    expect(dependencies, hasLength(3));
    expect(
      catalog.image(r'avg_4223_botany_1#1$1', kind: 'cutin').toString(),
      r'https://media.prts.wiki/7/7d/Avg_avg_4223_botany_1-1$1.png',
    );
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
    expect(
      (await offlineRepository.loadIndex()).every(
        (group) => group.entryType == 'GAMEPLAY',
      ),
      isTrue,
    );
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
  test('PRTS 剧情页可缓存并离线读取', () async {
    final cache = MemoryCache();
    const entry = StoryEntry('序章', 'https://prts.wiki/w/RO-BEG/NBT');
    final store = AssetStore(
      cache: cache,
      client: MockClient(
        (request) async => request.url.host == 'prts.wiki'
            ? http.Response(
                jsonEncode({
                  'parse': {
                    'text': {'*': '<pre id="datas_txt">[name="甲"]对白</pre>'},
                  },
                }),
                200,
                headers: {'content-type': 'text/html; charset=utf-8'},
              )
            : http.Response('{}', 200),
      ),
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
    final document = await StoryRepository(offline).loadEntry(entry);
    expect(document.title, '序章');
    expect(document.script.commands.single.text, '对白');
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
  for (final waitingForScript in [false, true]) {
    test('删除保护活跃剧情素材（依赖尚未解析：$waitingForScript）', () async {
      final cache = MemoryCache();
      final started = Completer<void>();
      final release = Completer<void>();
      var downloadingSecond = false;
      final store = AssetStore(
        cache: cache,
        client: MockClient((request) async {
          if (downloadingSecond &&
              (waitingForScript
                  ? request.url.path.endsWith('second.txt')
                  : request.url.path.endsWith('second.png'))) {
            started.complete();
            await release.future;
          }
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
          return request.url.path.endsWith('.png')
              ? http.Response.bytes([1], 200)
              : http.Response('{}', 200);
        }),
      );
      addTearDown(store.close);
      final repository = StoryRepository(store);
      const first = StoryEntry('第一幕', 'test/first');
      const second = StoryEntry('第二幕', 'test/second');
      expect(await repository.cacheEntry(first), isEmpty);
      downloadingSecond = true;
      final operation = repository.cacheEntry(second, control: CacheControl());
      await started.future;
      expect(await repository.deleteCachedStory(first), !waitingForScript);
      final shared = Uri.parse(
        'https://torappu.prts.wiki/assets/avg/background/shared.png',
      );
      expect(cache.data[shared], isNotNull);
      expect(await repository.cachedStories(), isEmpty);
      release.complete();
      expect(await operation, isEmpty);
      expect(await repository.cachedStories(), {second.path});
      store.releaseMemory();
      final prepared = await repository.prepare(
        await repository.loadEntry(second),
      );
      expect(prepared.warnings, isEmpty);
      expect(cache.data[shared], isNotNull);
    });
  }

  test('取消缓存后不会提交离线记录', () async {
    final cache = MemoryCache();
    final control = CacheControl();
    final store = AssetStore(
      cache: cache,
      client: MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(
            request.url.path.endsWith('.txt') ? '[name="甲"]对白' : '{}',
          ),
          200,
        ),
      ),
    );
    addTearDown(store.close);
    final repository = StoryRepository(store);
    const entry = StoryEntry('取消', 'test/cancel');
    await expectLater(
      repository.cacheEntry(
        entry,
        control: control,
        onProgress: (done, total) {
          if (done == total) control.cancel();
        },
      ),
      throwsA(isA<CacheCancelled>()),
    );
    expect(await repository.cachedStories(), isEmpty);
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
  test('玩法目录在线更新并在断网时使用上次成功结果', () async {
    final cache = MemoryCache();
    var version = '旧结局';
    var offline = false;
    final store = AssetStore(
      cache: cache,
      client: MockClient((request) async {
        if (request.url == StoryRepository.gameplayIndexUri) {
          if (offline) throw http.ClientException('离线');
          return http.Response(
            jsonEncode({
              'parse': {
                'text': {
                  '*':
                      '<table><tr><th>活动剧情一览</th></tr><tr><th rowspan="1">集成战略</th><th>新主题</th><td><a href="/w/NEW/NBT">$version</a></td></tr></table>',
                },
              },
            }),
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
        return http.Response('{}', 200);
      }),
    );
    addTearDown(store.close);
    final repository = StoryRepository(store);
    expect((await repository.loadIndex()).single.entries.single.title, '旧结局');
    version = '新结局';
    expect((await repository.loadIndex()).single.entries.single.title, '新结局');
    offline = true;
    expect((await repository.loadIndex()).single.entries.single.title, '新结局');
    await repository.clearCache();
    expect((await repository.loadIndex()).single.entries.single.title, '新结局');
  });
  test(
    'PRTS HTML 从 datas_txt 提取脚本；索引使用实际 storyTxt 且不按 storyCanShow 过滤',
    () async {
      final store = AssetStore(
        cache: MemoryCache(),
        client: MockClient((r) async {
          if (r.url == StoryRepository.gameplayIndexUri) {
            return http.Response(
              jsonEncode({
                'parse': {
                  'text': {
                    '*': '''<table><tr><th>活动剧情一览</th></tr>
              <tr><th rowspan="2">特殊</th><th>剧情</th><td><a href="/w/Test/END">多维合作</a></td></tr>
              <tr><th>危机合约</th><td><a href="/w/CC/NBT">危机合约</a></td></tr>
              <tr><th rowspan="2">集成战略</th><th>刻俄柏的灰蕈迷境</th><td><a href="/w/RO-BEG/NBT">序章</a></td></tr>
              <tr><th>新增主题</th><td><a href="/w/NEW/NBT">新结局</a></td></tr>
              <tr><th rowspan="1">生息演算</th><th>不包含</th><td><a href="/w/OTHER">其他</a></td></tr>
            </table>''',
                  },
                },
              }),
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            );
          }
          if (r.url.path == '/api.php') {
            return http.Response(
              jsonEncode({
                'parse': {
                  'text': {'*': '<pre id="datas_txt">[name="甲"]对白</pre>'},
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
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
                'id': 'chapter-id',
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
      expect(groups.first.name, '测试章节');
      expect(groups.first.id, 'chapter-id');
      // storyCanShow=0 的主线与干员密录同样进目录，否则整类剧情会被滤掉。
      expect(groups.first.entries.map((e) => e.path), [
        'obt/test/story',
        'obt/test/hidden',
      ]);
      expect(groups.first.entries.first.title, 'TEST 测试 行动前');
      expect(groups.first.entryType, 'MAINLINE');
      expect(groups.first.entries.first.code, 'TEST');
      expect(groups.first.entries.first.name, '测试');
      expect(groups.first.entries.first.tag, '行动前');
      final gameplay = groups
          .where((group) => group.entryType == 'GAMEPLAY')
          .toList();
      expect(gameplay.map((group) => group.name), [
        '特殊',
        '危机合约',
        '刻俄柏的灰蕈迷境',
        '新增主题',
      ]);
      final ro0 = gameplay.singleWhere((group) => group.id == 'rogue_0');
      expect(ro0.entries.single.path, 'https://prts.wiki/w/RO-BEG/NBT');
      expect(
        (await repository.loadEntry(ro0.entries.single))
            .script
            .commands
            .single
            .text,
        '对白',
      );
      expect(const StoryGroup('旧调用', []).entryType, 'NONE');
      expect(const StoryEntry('旧标题', 'old/path').name, isEmpty);
    },
  );

  test('玩法条目页面名先解码再请求 API，避免双重编码', () async {
    String? requestedPage;
    final store = AssetStore(
      cache: MemoryCache(),
      client: MockClient((r) async {
        if (r.url.path == '/api.php') {
          requestedPage = r.url.queryParameters['page'];
          if (requestedPage == '危机合约/剧情' ||
              requestedPage == 'RO-BEG/NBT') {
            return http.Response(
              jsonEncode({
                'parse': {
                  'title': requestedPage,
                  'text': {'*': '<pre id="datas_txt">[name="甲"]对白</pre>'},
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          // MediaWiki 对非法标题（如双重编码产生的字面量“%E5%8D%B1…”）
          // 的真实响应是 HTTP 200 + error JSON，而不是非 2xx 状态码。
          return http.Response(
            jsonEncode({
              'error': {'code': 'invalidtitle', 'info': 'Bad title'},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        fail('不应请求其他地址：${r.url}');
      }),
    );
    addTearDown(store.close);
    final repository = StoryRepository(store);
    // entry.path 是 _parseGameplayIndex 从 href 解析出的百分号编码形式。
    final document = await repository.loadEntry(
      StoryEntry(
        '危机合约',
        'https://prts.wiki/w/%E5%8D%B1%E6%9C%BA%E5%90%88%E7%BA%A6/%E5%89%A7%E6%83%85',
        name: '危机合约',
      ),
    );
    expect(requestedPage, '危机合约/剧情');
    expect(document.title, '危机合约');
    expect(document.script.commands.single.text, '对白');
    // ASCII 页面名解码后保持原样，既有缓存地址不变。
    requestedPage = null;
    await repository.loadEntry(
      const StoryEntry('序章', 'https://prts.wiki/w/RO-BEG/NBT', name: '序章'),
    );
    expect(requestedPage, 'RO-BEG/NBT');
  });

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
