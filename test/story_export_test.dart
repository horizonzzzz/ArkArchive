import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:crypto/crypto.dart';

import 'package:arknights_story_player/story_player/data/asset_package.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/data/cache_control.dart';
import 'package:arknights_story_player/story_player/data/export_target.dart';
import 'package:arknights_story_player/story_player/data/export_target_android.dart';
import 'package:arknights_story_player/story_player/data/export_target_desktop.dart';
import 'package:arknights_story_player/story_player/data/file_cache.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/data/preview_cache.dart';
import 'package:arknights_story_player/story_player/data/story_export.dart';
import 'package:arknights_story_player/story_player/script.dart';

class MemoryCache extends FileCache {
  final Map<Uri, Uint8List> data = {};
  final Map<String, Map<Uri, Uint8List>> stories = {};

  @override
  Future<Uint8List?> read(
    Uri uri, {
    String? story,
    bool allowShared = true,
  }) async =>
      stories[story]?[uri] ?? (story == null || allowShared ? data[uri] : null);

  @override
  Future<void> write(Uri uri, Uint8List bytes, {String? story}) async {
    (story == null ? data : stories.putIfAbsent(story, () => {}))[uri] = bytes;
  }

  @override
  Future<int?> sizeOf(Uri uri, {String? story}) async =>
      (stories[story]?[uri] ?? (story == null ? null : data[uri]))?.length;
}

MediaCatalog _catalog() => MediaCatalog(
  variables: {
    'reunion_loop': 'Sound_Beta_2/Music/AVG/m_avg_ReunionNormal_loop',
    'reunion_intro': 'Sound_Beta_2/Music/AVG/m_avg_ReunionNormal_intro',
    'slash': 'Sound_Beta_2/CustomSE/act24side#retro/slash_1',
    'battle_loop': 'Sound_Beta_2/Music/AVG/m_avg_battle_loop',
  },
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
  backgroundPpu: {},
);

const _script = r'''
[PlayMusic(key="$reunion_loop",intro="$reunion_intro")]
[PlayMusic(key="$reunion_loop")]
[PlaySound(key="$slash")]
[PlaySound(key="$battle_loop")]
[Background(image="bg_forest")]
[Image(image="cg_tower")]
[GridBG(imagegroup="bg_a/bg_b")]
[CharSlot(slot="m",name="actor#1")]
[CharSlot(slot="r",name="actor#2")]
[Interlude(channel=3,type=2,name="bg_extra")]
[CgItem(image="item_map")]
[AvgDisplay(style=5,slot=1,name="snow")]
''';

void main() {
  test('collect 聚合条目：BGM 合并前奏、立绘合并差分、同名图片去重', () {
    final catalog = _catalog();
    final warnings = <String>[];
    final refs = catalog.collect(StoryScript.parse(_script), warnings);
    final package = AssetPackage.fromRefs(
      storyTitle: '14-11 行动后',
      storyPath: 'obt/main/level_main_14-10_beg',
      groupName: '主线篇章',
      entryType: 'MAINLINE',
      refs: refs,
      script: [
        AssetFile(
          Uri.parse(
            'https://torappu.prts.wiki/gamedata/latest/story/obt/main/level_main_14-10_beg.txt',
          ),
          'script/level_main_14-10_beg.txt',
        ),
      ],
      unresolved: warnings,
    );

    final music = package.itemsOfKinds({AssetKind.music});
    expect(music, hasLength(1));
    expect(music.single.title, 'm_avg_reunionnormal');
    expect(music.single.files.map((file) => file.exportPath), [
      'audio/music/avg/m_avg_reunionnormal_loop.mp3',
      'audio/music/avg/m_avg_reunionnormal_intro.mp3',
    ]);

    final sfx = package.itemsOfKinds({AssetKind.sfx});
    expect(sfx, hasLength(2));
    // 路径段里的 # 必须出现在解码后的导出路径中。
    expect(
      sfx
          .map((item) => item.files.single.exportPath)
          .where((path) => path.contains('act24side')),
      contains('audio/customse/act24side#retro/slash_1.mp3'),
    );

    final characters = package.itemsOfKinds({AssetKind.character});
    expect(characters, hasLength(1));
    expect(characters.single.title, 'actor');
    expect(characters.single.files, hasLength(3));
    expect(characters.single.preview.pathSegments.last, r'actor$1.png');
    expect(
      characters.single.files.map((file) => file.exportPath),
      allOf(
        contains(r'characters/actor/actor$1.png'),
        contains(r'characters/actor/2$1.png'),
      ),
    );

    final backgrounds = package.itemsOfKinds({AssetKind.background});
    expect(backgrounds, hasLength(5)); // bg_forest、bg_a、bg_b、bg_extra、snow
    expect(
      backgrounds.map((item) => item.files.single.exportPath),
      containsAll([
        'images/background/bg_forest.png',
        'images/background/bg_a.png',
        'images/background/bg_extra.png',
        'images/background/snow.png',
      ]),
    );
    expect(
      package
          .itemsOfKinds({AssetKind.cg})
          .map((item) => item.files.single.exportPath),
      contains('images/cg/cg_tower.png'),
    );
    expect(
      package
          .itemsOfKinds({AssetKind.other})
          .map((item) => item.files.single.exportPath),
      contains('images/item/item_map.png'),
    );

    final script = package.itemsOfKinds({AssetKind.script}).single;
    expect(script.files.single.exportPath, 'script/level_main_14-10_beg.txt');
    expect(script.title, 'level_main_14-10_beg.txt');
  });

  test('不同来源落到同一路径时分配唯一路径，manifest 记录实际路径', () {
    final first = Uri.parse('https://one.test/a.mp3');
    final second = Uri.parse('https://two.test/a.mp3');
    final package = AssetPackage.fromRefs(
      storyTitle: '标题',
      storyPath: 'story',
      groupName: '',
      entryType: 'NONE',
      refs: [
        AssetRef(AssetKind.music, 'first', [AssetFile(first, 'extras/a.mp3')]),
        AssetRef(AssetKind.sfx, 'second', [AssetFile(second, 'extras/a.mp3')]),
      ],
      script: [],
      unresolved: [],
    );
    final paths = [
      for (final item in package.items) item.files.single.exportPath,
    ];
    expect(paths.toSet(), hasLength(2));
    expect(paths.first, 'extras/a.mp3');
    expect(paths.last, matches(RegExp(r'^extras/a_[0-9a-f]{8}\.mp3$')));
    expect(package.fileCount, 2);
  });

  test('清洗后的文件名同时用于写盘与 manifest；跨分类共享来源各写一份', () async {
    final cache = MemoryCache();
    final shared = Uri.parse('https://example.test/shared.png');
    final dirty = Uri.parse('https://example.test/dirty.png');
    await cache.write(shared, Uint8List.fromList([1, 2]), story: 'story');
    await cache.write(dirty, Uint8List.fromList([3]), story: 'story');
    var requests = 0;
    final store = AssetStore(
      cache: cache,
      client: MockClient((request) async {
        requests++;
        return http.Response('net', 200);
      }),
    );
    addTearDown(store.close);
    final package = AssetPackage.fromRefs(
      storyTitle: '标题',
      storyPath: 'story',
      groupName: '',
      entryType: 'NONE',
      refs: [
        // 同一来源被 CG 与道具图各引用一次：路径不同、各写一份。
        AssetRef(AssetKind.cg, 'shared', [
          AssetFile(shared, 'images/cg/shared.png'),
        ]),
        AssetRef(AssetKind.other, 'shared', [
          AssetFile(shared, 'images/item/shared.png'),
        ]),
        // 非法字符在定稿时清洗，manifest 不能记录原名。
        AssetRef(AssetKind.background, 'dirty', [
          AssetFile(dirty, 'images/background/a:b?.png'),
        ]),
      ],
      script: [],
      unresolved: [],
    );
    final target = ExportTarget(backend: DesktopExportBackend());
    final dir = await Directory.systemTemp.createTemp('export-unique-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final result = await StoryExporter(store).export(
      target: target,
      package: package,
      items: package.items,
      parentPath: dir.path,
    );
    expect(result.failures, isEmpty);
    expect(requests, 0);
    expect(
      File('${result.rootPath}/images/cg/shared.png').existsSync(),
      isTrue,
    );
    expect(
      File('${result.rootPath}/images/item/shared.png').existsSync(),
      isTrue,
    );
    expect(
      File('${result.rootPath}/images/background/a_b_.png').existsSync(),
      isTrue,
    );
    final manifest = jsonDecode(
      await File('${result.rootPath}/manifest.json').readAsString(),
    ) as Map<String, dynamic>;
    final paths = [
      for (final file in manifest['files'] as List) (file as Map)['path'],
    ];
    expect(
      paths,
      containsAll([
        'images/cg/shared.png',
        'images/item/shared.png',
        'images/background/a_b_.png',
      ]),
    );
    expect(paths, isNot(contains('images/background/a:b?.png')));
    expect(result.fileCount, 3);
  });

  test('collect 的文件并集与 dependencies 完全一致', () {
    final catalog = _catalog();
    final warnings = <String>[];
    final script = StoryScript.parse(r'''
[PlayMusic(key="$reunion_loop",intro="$reunion_intro")]
[PlaySound(key="$slash")]
[Background(image="bg_forest")]
[CharSlot(slot="m",name="actor#1")]
[Interlude(channel=3,type=3,name="actor#2")]
[Interlude(channel=3,type=3,name="missing_char")]
''');
    expect({
      for (final ref in catalog.collect(script, warnings)) ...[
        for (final file in ref.files) file.uri,
      ],
    }, catalog.dependencies(script, [...warnings]));
  });

  test('未解析音频进入 warnings，不产生条目', () {
    final catalog = _catalog();
    final warnings = <String>[];
    final refs = catalog.collect(
      StoryScript.parse(r'[PlaySound(key="$missing")]'),
      warnings,
    );
    expect(refs, isEmpty);
    expect(warnings.single, contains('未解析音频'));
  });

  test('sanitizeFileName 清洗非法字符与结尾点空格', () {
    expect(sanitizeFileName(r'a<b>:c"/d\e|f?g*h'), 'a_b__c__d_e_f_g_h');
    expect(sanitizeFileName('name.'), 'name');
    expect(sanitizeFileName(' trailing '), 'trailing');
    expect(sanitizeFileName('///'), '___'); // 全非法字符替换后仍合法
  });

  test('exportDirectoryName 保留章节层级并清洗两端', () {
    expect(
      exportDirectoryName(groupName: '主线篇章', title: '14-11 行动后'),
      '主线篇章/14-11 行动后',
    );
    expect(exportDirectoryName(groupName: '', title: '标题'), '标题');
  });

  test('loadTransient 缓存命中不联网，故事层优先于共享层', () async {
    final storyUri = Uri.parse('https://example.test/story.png');
    final sharedUri = Uri.parse('https://example.test/shared.png');
    final cache = MemoryCache();
    await cache.write(storyUri, Uint8List.fromList([1]), story: 'story');
    await cache.write(sharedUri, Uint8List.fromList([2]));
    var requests = 0;
    final store = AssetStore(
      cache: cache,
      client: MockClient((request) async {
        requests++;
        return http.Response('no', 200);
      }),
    );
    addTearDown(store.close);
    expect(await store.loadTransient(storyUri, story: 'story'), [1]);
    expect(await store.loadTransient(sharedUri, story: 'story'), [2]);
    expect(requests, 0);
  });

  test('loadTransient 未缓存走网络并拒绝 HTML 伪装，主地址失败换备用地址', () async {
    final primary = Uri.parse('https://example.test/script.txt');
    final mirror = Uri.parse('https://mirror.test/script.txt');
    final fakePng = Uri.parse('https://example.test/fake.png');
    final requested = <Uri>[];
    final cache = MemoryCache();
    final store = AssetStore(
      cache: cache,
      client: MockClient((request) async {
        requested.add(request.url);
        if (request.url == primary) {
          return http.Response('gone', 404);
        }
        if (request.url == fakePng) {
          return http.Response(
            '<html></html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        }
        return http.Response('mirror', 200);
      }),
    );
    addTearDown(store.close);
    expect(
      await store.loadTransient(primary, alternates: [mirror]),
      utf8.encode('mirror'),
    );
    expect(requested, [primary, mirror]);
    expect(cache.data, isEmpty);
    expect(store.loadTransient(fakePng), throwsA(isA<FormatException>()));
  });

  test('cachedSize 只查磁盘不联网，故事层未命中回退共享层', () async {
    final uri = Uri.parse('https://example.test/a.mp3');
    final sharedOnly = Uri.parse('https://example.test/b.mp3');
    final missing = Uri.parse('https://example.test/c.mp3');
    final cache = MemoryCache();
    await cache.write(
      uri,
      Uint8List.fromList(List.filled(10, 0)),
      story: 'story',
    );
    await cache.write(sharedOnly, Uint8List.fromList(List.filled(4, 0)));
    final store = AssetStore(
      cache: cache,
      client: MockClient((request) async => fail('不应联网')),
    );
    addTearDown(store.close);
    expect(await store.cachedSize(uri, story: 'story'), 10);
    expect(await store.cachedSize(sharedOnly, story: 'story'), 4);
    expect(await store.cachedSize(missing, story: 'story'), isNull);
  });

  test('PreviewCache 命中不重复加载并按 LRU 淘汰', () async {
    final loads = <Uri>[];
    Uint8List chunk(int size) => Uint8List.fromList(List.filled(size, 7));
    final cache = PreviewCache((uri) async {
      loads.add(uri);
      return chunk(uri.pathSegments.last == 'a.png' ? 60 : 30);
    }, maxBytes: 100);
    final a = Uri.parse('https://example.test/a.png');
    final b = Uri.parse('https://example.test/b.png');
    await cache.load(a);
    await cache.load(a);
    expect(loads, [a]);
    await cache.load(b);
    await cache.load(Uri.parse('https://example.test/c.png'));
    // a（60B）已随 c 的写入被淘汰，重新访问会再次加载。
    await cache.load(a);
    expect(loads, [a, b, Uri.parse('https://example.test/c.png'), a]);
  });

  test('导出已缓存条目不联网并生成 manifest；单文件失败不中断', () async {
    final cache = MemoryCache();
    final good = Uri.parse('https://example.test/good.png');
    final bad = Uri.parse('https://example.test/bad.png');
    final network = Uri.parse('https://example.test/online.png');
    await cache.write(good, Uint8List.fromList([1, 2, 3]), story: 'story');
    var requests = 0;
    final store = AssetStore(
      cache: cache,
      client: MockClient((request) async {
        requests++;
        if (request.url == bad) return http.Response('boom', 500);
        return http.Response('net', 200);
      }),
    );
    addTearDown(store.close);
    final package = AssetPackage.fromRefs(
      storyTitle: '14-11 行动后',
      storyPath: 'story',
      groupName: '',
      entryType: 'MAINLINE',
      refs: [
        AssetRef(AssetKind.background, 'good', [
          AssetFile(good, 'images/background/good.png'),
        ]),
        AssetRef(AssetKind.cg, 'bad', [AssetFile(bad, 'images/cg/bad.png')]),
        AssetRef(AssetKind.cg, 'online', [
          AssetFile(network, 'images/cg/online.png'),
        ]),
      ],
      script: [],
      unresolved: [r'未解析音频：$xxx'],
    );
    final target = ExportTarget(backend: DesktopExportBackend());
    final dir = await Directory.systemTemp.createTemp('export-test-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final exporter = StoryExporter(store);
    var lastProgress = (0, 0, 0);
    final result = await exporter.export(
      target: target,
      package: package,
      items: package.items,
      parentPath: dir.path,
      appVersion: '1.1.2',
      onProgress: (done, total, bytes) => lastProgress = (done, total, bytes),
    );
    expect(requests, 2); // bad 与 online 各请求一次，good 走缓存
    expect(result.completed, isFalse);
    expect(result.fileCount, 2);
    expect(result.failures, hasLength(1));
    expect(result.failures.single.exportPath, 'images/cg/bad.png');
    expect(lastProgress, (3, 3, 3 + utf8.encode('net').length));
    expect(
      File('${result.rootPath}/images/background/good.png').readAsBytes(),
      completion([1, 2, 3]),
    );
    final manifest = jsonDecode(
      await File('${result.rootPath}/manifest.json').readAsString(),
    ) as Map<String, dynamic>;
    expect(manifest['version'], '1.1.2');
    expect(manifest['story']['path'], 'story');
    expect(manifest['unresolved'], [r'未解析音频：$xxx']);
    final files = manifest['files'] as List;
    expect(files, hasLength(2));
    final first = files.first as Map<String, dynamic>;
    expect(first['sha256'], sha256.convert([1, 2, 3]).toString());
    expect((manifest['failed'] as List), hasLength(1));
  });

  test('取消导出抛出并清理未完成的目录', () async {
    final store = AssetStore(
      client: MockClient((request) async => http.Response('net', 200)),
    );
    addTearDown(store.close);
    final package = AssetPackage.fromRefs(
      storyTitle: '标题',
      storyPath: 'story',
      groupName: '',
      entryType: 'NONE',
      refs: [
        AssetRef(AssetKind.background, 'a', [
          AssetFile(
            Uri.parse('https://example.test/a.png'),
            'images/background/a.png',
          ),
        ]),
      ],
      script: [],
      unresolved: [],
    );
    final control = CacheControl();
    final target = ExportTarget(backend: DesktopExportBackend());
    final dir = await Directory.systemTemp.createTemp('export-test-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final exporter = StoryExporter(store);
    final pending = exporter.export(
      target: target,
      package: package,
      items: package.items,
      parentPath: dir.path,
      control: control,
    );
    await pumpEventQueue();
    control.cancel();
    await expectLater(pending, throwsA(isA<CacheCancelled>()));
    // 取消后由调用方清理未完成的目录，不留半成品。
    final rootPath = target.rootPath;
    await target.deleteDirectory();
    expect(target.rootPath, isNull);
    expect(Directory(rootPath!).existsSync(), isFalse);
  });

  test('ExportTarget 末层冲突加序号，文件名清洗，删除目录', () async {
    final dir = await Directory.systemTemp.createTemp('export-target-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final target = ExportTarget(backend: DesktopExportBackend());
    final root = await target.createDirectory(dir.path, '章节/标题');
    expect(
      root,
      '${dir.path}${Platform.pathSeparator}章节${Platform.pathSeparator}标题',
    );
    // 同名目标不覆盖：第二个任务实例会拿到带序号的目录。
    final secondTarget = ExportTarget(backend: DesktopExportBackend());
    final second = await secondTarget.createDirectory(dir.path, '章节/标题');
    expect(second, endsWith('标题 (2)'));
    await secondTarget.deleteDirectory();
    await target.writeFile('images/bg/what<ever>.png', [1]);
    expect(
      Directory(
        '$root${Platform.pathSeparator}images${Platform.pathSeparator}bg',
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        '$root${Platform.pathSeparator}images${Platform.pathSeparator}bg${Platform.pathSeparator}what_ever_.png',
      ).existsSync(),
      isTrue,
    );
    await target.deleteDirectory();
    expect(Directory(root).existsSync(), isFalse);
    expect(target.rootPath, isNull);
  });

  test('默认导出路径不存在时自动创建，首次直接导出即可成功', () async {
    final base = await Directory.systemTemp.createTemp('export-default-');
    addTearDown(() async {
      if (await base.exists()) await base.delete(recursive: true);
    });
    // 模拟「下载目录/方舟档案室」：拼接出来、从未创建过的默认路径。
    final missing = '${base.path}${Platform.pathSeparator}方舟档案室';
    expect(Directory(missing).existsSync(), isFalse);
    final target = ExportTarget(backend: DesktopExportBackend());
    final root = await target.createDirectory(missing, '主线篇章/14-11 行动后');
    expect(
      root,
      '$missing${Platform.pathSeparator}主线篇章${Platform.pathSeparator}14-11 行动后',
    );
    await target.writeFile('manifest.json', [1]);
    expect(
      File('$root${Platform.pathSeparator}manifest.json').existsSync(),
      isTrue,
    );
    await target.deleteDirectory();
    // 只清理半成品根目录；自动创建的父级目录保留，不连带删除。
    expect(Directory(root).existsSync(), isFalse);
    expect(Directory(missing).existsSync(), isTrue);
  });

  test('ExportTarget 按平台分发：Android 选 zip 后端，桌面选目录后端', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      expect(ExportTarget().supportsDirectorySelection, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(ExportTarget().supportsDirectorySelection, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('Android 后端提供 zip 分享文案，桌面后端提供目录文案', () {
    final android = AndroidExportBackend();
    expect(android.supportsDirectorySelection, isFalse);
    expect(
      android.destinationSummary('', '主线篇章/14-11 行动后'),
      '打包为 主线篇章_14-11 行动后.zip，完成后通过系统分享保存',
    );
    expect(
      android.describeCompletion('主线篇章_14-11 行动后.zip'),
      '素材已打包为 主线篇章_14-11 行动后.zip',
    );
    expect(android.openActionLabel, '分享');

    final desktop = DesktopExportBackend();
    expect(desktop.supportsDirectorySelection, isTrue);
    expect(
      desktop.destinationSummary(r'C:\Exports', '主线篇章/14-11 行动后'),
      r'保存到 C:\Exports/主线篇章/14-11 行动后',
    );
    expect(desktop.describeCompletion('目录'), '素材已导出到 目录');
    expect(desktop.openActionLabel, '打开文件夹');
  });

  test('Android 导出把素材逐文件写入 zip，manifest 也在包内；分享手动拉起', () async {
    final cache = MemoryCache();
    final good = Uri.parse('https://example.test/good.png');
    final script = Uri.parse('https://example.test/story.txt');
    await cache.write(good, Uint8List.fromList([1, 2, 3]), story: 'story');
    await cache.write(
      script,
      Uint8List.fromList(utf8.encode('剧情脚本')),
      story: 'story',
    );
    final store = AssetStore(
      cache: cache,
      client: MockClient((request) async => fail('已缓存条目不应联网')),
    );
    addTearDown(store.close);
    final package = AssetPackage.fromRefs(
      storyTitle: '14-11 行动后',
      storyPath: 'story',
      groupName: '主线篇章',
      entryType: 'MAINLINE',
      refs: [
        AssetRef(AssetKind.background, 'good', [
          AssetFile(good, 'images/background/good.png'),
        ]),
      ],
      script: [AssetFile(script, 'script/14-11 行动后.txt')],
      unresolved: [],
    );
    final base = await Directory.systemTemp.createTemp('export-zip-');
    addTearDown(() async {
      if (await base.exists()) await base.delete(recursive: true);
    });
    final shared = <(String, String)>[];
    final target = ExportTarget(
      backend: AndroidExportBackend(
        cacheDirectory: () async => base,
        share: (path, displayName) async => shared.add((path, displayName)),
      ),
    );
    final result = await StoryExporter(store).export(
      target: target,
      package: package,
      items: package.items,
      // 移动端没有目录概念，parentPath 一律忽略。
      parentPath: '/storage/emulated/0/ignored',
      appVersion: '1.2.0',
    );
    expect(result.completed, isTrue);
    // 展示位置是压缩包文件名，不是应用内部路径。
    expect(result.rootPath, '主线篇章_14-11 行动后.zip');
    final zipPath =
        '${base.path}${Platform.pathSeparator}方舟档案室导出'
        '${Platform.pathSeparator}主线篇章_14-11 行动后.zip';
    final archive = ZipDecoder().decodeBytes(await File(zipPath).readAsBytes());
    expect(
      [for (final entry in archive.files) entry.name],
      containsAll([
        'images/background/good.png',
        'script/14-11 行动后.txt',
        'manifest.json',
      ]),
    );
    expect(archive.findFile('images/background/good.png')!.content, [1, 2, 3]);
    final manifest = jsonDecode(
      utf8.decode(archive.findFile('manifest.json')!.content as Uint8List),
    ) as Map<String, dynamic>;
    expect(manifest['version'], '1.2.0');
    expect(manifest['story']['title'], '14-11 行动后');
    // 完成不自动拉起分享面板，由用户在结果页或提示条手动分享。
    expect(shared, isEmpty);
    await target.openResult();
    expect(shared.single, (zipPath, '主线篇章_14-11 行动后.zip'));
  });

  test('Android 同名 zip 追加序号不覆盖；取消删除半成品', () async {
    final base = await Directory.systemTemp.createTemp('export-zip-unique-');
    addTearDown(() async {
      if (await base.exists()) await base.delete(recursive: true);
    });
    String zipOf(String name) =>
        '${base.path}${Platform.pathSeparator}方舟档案室导出'
        '${Platform.pathSeparator}$name';
    final target = ExportTarget(
      backend: AndroidExportBackend(cacheDirectory: () async => base),
    );
    expect(
      await target.createDirectory('', '主线篇章/14-11 行动后'),
      '主线篇章_14-11 行动后.zip',
    );
    final secondTarget = ExportTarget(
      backend: AndroidExportBackend(cacheDirectory: () async => base),
    );
    expect(
      await secondTarget.createDirectory('', '主线篇章/14-11 行动后'),
      '主线篇章_14-11 行动后 (2).zip',
    );
    await target.writeFile('images/bg/a.png', [1]);
    await target.commit();
    expect(File(zipOf('主线篇章_14-11 行动后.zip')).existsSync(), isTrue);
    // 未提交的第二个包取消后删除，不影响已提交的第一个包。
    await secondTarget.deleteDirectory();
    expect(secondTarget.rootPath, isNull);
    expect(File(zipOf('主线篇章_14-11 行动后 (2).zip')).existsSync(), isFalse);
    expect(File(zipOf('主线篇章_14-11 行动后.zip')).existsSync(), isTrue);
  });
  test('Android 并发同名导出独占不同 zip，两个包均可解压', () async {
    final base = await Directory.systemTemp.createTemp('export-zip-race-');
    addTearDown(() async {
      if (await base.exists()) await base.delete(recursive: true);
    });
    final first = ExportTarget(
      backend: AndroidExportBackend(cacheDirectory: () async => base),
    );
    final second = ExportTarget(
      backend: AndroidExportBackend(cacheDirectory: () async => base),
    );
    final names = await Future.wait([
      first.createDirectory('', '章节/同名'),
      second.createDirectory('', '章节/同名'),
    ]);
    expect(names.toSet(), {'章节_同名.zip', '章节_同名 (2).zip'});
    await Future.wait([
      first.writeFile('payload.txt', [1]),
      second.writeFile('payload.txt', [2]),
    ]);
    await Future.wait([first.commit(), second.commit()]);
    final folder = Directory('${base.path}${Platform.pathSeparator}方舟档案室导出');
    // Future.wait 保留输入顺序，但先占到原始文件名的任务不固定。
    for (final (index, name) in names.indexed) {
      final archive = ZipDecoder().decodeBytes(
        await File('${folder.path}${Platform.pathSeparator}$name')
            .readAsBytes(),
      );
      expect(archive.findFile('payload.txt')!.content, [index + 1]);
    }
  });
}
