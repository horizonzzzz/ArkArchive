import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/data/file_cache.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/data/story_repository.dart';
import 'package:arknights_story_player/story_player/script.dart';

class MemoryCache extends FileCache {
  final Map<Uri, Uint8List> data = {};
  @override
  Future<Uint8List?> read(Uri uri) async => data[uri];
  @override
  Future<void> write(Uri uri, Uint8List bytes) async {
    data[uri] = bytes;
  }

  @override
  Future<Uri> playableUri(Uri uri) async => uri;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('PRTS HTML 从 datas_txt 提取脚本；索引使用实际 storyTxt 而非预置关卡', () async {
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
    expect(groups.single.entries.single.path, 'obt/test/story');
    expect(groups.single.entries.single.title, 'TEST 测试 行动前');
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
}
