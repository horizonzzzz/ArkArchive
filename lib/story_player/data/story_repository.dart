import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../script.dart';
import 'asset_store.dart';
import 'cache_control.dart';
import 'media_catalog.dart';

const _gameplayIds = <String, String>{
  '特殊': 'special',
  '危机合约': 'crisis',
  '荷谟伊智境': 'act1lock',
  '长夜临光': 'act13side',
  '断罪者的挑战状': 'apf2020',
  '泰拉 说唱之夜！': 'apf2021',
  '狂弹要塞！罗德大兵集结': 'act3fun',
  '主播U：全能系美少女': 'act4fun',
  '好得不能再好了！泰拉投资大师课': 'act5fun',
  'ARKnoNIGHTS': 'act6fun',
  'Rhodes Island Epic 黑色博士坠落': 'act7fun',
  '刻俄柏的灰蕈迷境': 'rogue_0',
  '傀影与猩红孤钻': 'rogue_1',
  '水月与深蓝之树': 'rogue_2',
  '探索者的银凇止境': 'rogue_3',
  '萨卡兹的无终奇语': 'rogue_4',
  '岁的界园志异': 'rogue_5',
  '沉沦者的黑流树海': 'rogue_6',
};

class StoryDocument {
  const StoryDocument({required this.title, required this.script});
  final String title;
  final StoryScript script;
}

class StoryEntry {
  const StoryEntry(
    this.title,
    this.path, {
    this.code = '',
    this.name = '',
    this.tag = '',
  });
  final String title;
  final String path;
  final String code;
  final String name;
  final String tag;
}

class StoryGroup {
  const StoryGroup(
    this.name,
    this.entries, {
    this.entryType = 'NONE',
    this.id = '',
  });
  final String name;
  final List<StoryEntry> entries;
  final String entryType;
  final String id;
}

class StoryRepository {
  StoryRepository(this.store);
  final AssetStore store;

  /// PRTS 静态数据站同时提供剧情索引和原始脚本，Web 端也允许跨域读取。
  static final indexUri = Uri.parse(
    'https://torappu.prts.wiki/gamedata/latest/excel/story_review_table.json',
  );
  static final storyBase = Uri.parse(
    'https://torappu.prts.wiki/gamedata/latest/story/',
  );
  static final gameplayIndexUri = _wikiApiUri('剧情一览');
  static Uri _wikiApiUri(String page) => Uri.https('prts.wiki', '/api.php', {
    'action': 'parse',
    'format': 'json',
    'prop': 'text',
    'origin': '*',
    'page': page,
  });

  static String _wikiApiHtml(String text) {
    final data = jsonDecode(text);
    final parsed = data is Map ? data['parse'] : null;
    final values = parsed is Map ? parsed['text'] : null;
    final content = values is Map ? values['*'] : null;
    if (content is! String || content.isEmpty) {
      throw const FormatException('PRTS 接口未返回页面内容');
    }
    return content;
  }

  static final _offlineIndexUri = Uri.parse(
    'https://local.invalid/offline-stories-v1',
  );
  Future<void> _indexWrite = Future.value();
  MediaCatalog? _cacheCatalog;
  final Map<String, Set<Uri>?> _activeAssets = {};

  Future<MediaCatalog> _loadCacheCatalog() async =>
      _cacheCatalog ??= await MediaCatalog.load(store);

  Uri _manifestUri(String path) =>
      Uri.https('local.invalid', '/story-cache-manifest-v1', {'story': path});

  Future<Set<Uri>?> _readManifest(String path) async {
    final data = await store.readCache(_manifestUri(path));
    if (data == null) return null;
    final values = (jsonDecode(utf8.decode(data)) as List).cast<String>();
    return values.map(Uri.parse).toSet();
  }

  Future<void> _changeCachedStories(void Function(Set<String>) change) {
    final write = _indexWrite.catchError((_) {}).then((_) async {
      final entries = await cachedStories();
      change(entries);
      await store.writeCache(
        _offlineIndexUri,
        utf8.encode(jsonEncode(entries.toList())),
      );
    });
    _indexWrite = write;
    return write;
  }

  Future<Set<String>> cachedStories() async {
    final data = await store.readCache(_offlineIndexUri);
    if (data == null) return {};
    return (jsonDecode(utf8.decode(data)) as List).cast<String>().toSet();
  }

  Future<void> clearCache() async {
    await _changeCachedStories((entries) => entries.clear());
    _cacheCatalog = null;
    // 保留目录供下次离线启动浏览，先撤销离线标记以防清理中途失败。
    await store.clearCache(keep: {indexUri, gameplayIndexUri});
  }

  Future<void> forgetCachedStory(StoryEntry entry) =>
      _changeCachedStories((entries) => entries.remove(entry.path));

  Future<bool> deleteCachedStory(StoryEntry entry) {
    final deletion = _indexWrite.catchError((_) {}).then((_) async {
      final entries = await cachedStories();
      if (!entries.remove(entry.path)) return false;
      Set<Uri>? owned;
      var safeToReclaim = true;
      try {
        owned = await _readManifest(entry.path);
        if (owned == null) safeToReclaim = false;
      } catch (_) {
        safeToReclaim = false;
      }
      final shared = <Uri>{indexUri, ...MediaCatalog.tableUris};
      // 未完成的剧情尚无离线清单，也必须保护它已经下载的共享素材。
      for (final assets in _activeAssets.values) {
        if (assets == null) {
          safeToReclaim = false;
        } else {
          shared.addAll(assets);
        }
      }
      for (final path in entries) {
        try {
          final manifest = await _readManifest(path);
          if (manifest == null) {
            safeToReclaim = false;
          } else {
            shared.addAll(manifest);
          }
        } catch (_) {
          safeToReclaim = false;
        }
      }
      await store.writeCache(
        _offlineIndexUri,
        utf8.encode(jsonEncode(entries.toList())),
      );
      if (safeToReclaim && owned != null) {
        for (final uri in owned.difference(shared)) {
          await store.deleteCache(uri);
        }
      }
      await store.deleteCache(_manifestUri(entry.path));
      return safeToReclaim;
    });
    _indexWrite = deletion.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return deletion;
  }

  Future<List<String>> cacheEntry(
    StoryEntry entry, {
    CacheControl? control,
    void Function(int, int)? onProgress,
  }) => store.runCacheDownload(() async {
    if (_activeAssets.containsKey(entry.path)) throw StateError('剧情正在缓存');
    _activeAssets[entry.path] = null;
    try {
      await control?.checkpoint();
      await _changeCachedStories((entries) => entries.remove(entry.path));
      final document = await loadEntry(entry);
      if (!document.script.commands.any(
        (c) => c.tag == 'dialogue' || c.text.isNotEmpty,
      )) {
        throw const FormatException('脚本中没有可播放内容');
      }
      final catalog = await _loadCacheCatalog();
      final warnings = <String>[];
      final assets = catalog.dependencies(document.script, warnings);
      _activeAssets[entry.path] = {
        indexUri,
        _entryUri(entry),
        ...MediaCatalog.tableUris,
        ...assets,
      };
      final errors = [...warnings];
      errors.addAll(
        await store.preload({
          indexUri,
          _entryUri(entry),
          ...MediaCatalog.tableUris,
          ...assets,
        }, onProgress: onProgress),
      );
      await control?.checkpoint();
      if (errors.isEmpty) {
        final manifest = {
          indexUri,
          _entryUri(entry),
          ...MediaCatalog.tableUris,
          ...assets,
        };
        await store.writeCache(
          _manifestUri(entry.path),
          utf8.encode(
            jsonEncode(manifest.map((uri) => uri.toString()).toList()),
          ),
        );
        await control?.checkpoint();
        await _changeCachedStories((entries) {
          if (control?.cancelled != true) entries.add(entry.path);
        });
        if (control?.cancelled == true) {
          await _changeCachedStories((entries) => entries.remove(entry.path));
          throw const CacheCancelled();
        }
      }
      return errors;
    } finally {
      _activeAssets.remove(entry.path);
    }
  }, control: control);
  Future<StoryDocument> load(Uri uri, {String? title}) async {
    final text = utf8.decode(await store.load(uri));
    if (uri.host == 'prts.wiki' || uri.host == 'www.prts.wiki') {
      final page = html.parse(
        uri.path == '/api.php' ? _wikiApiHtml(text) : text,
      );
      final script = page.querySelector('#datas_txt')?.text;
      if (script == null || script.trim().isEmpty) {
        throw const FormatException('页面没有 #datas_txt 剧情脚本');
      }
      return StoryDocument(
        title:
            title ??
            page.querySelector('#firstHeading')?.text.trim() ??
            uri.path,
        script: StoryScript.parse(script),
      );
    }
    if (text.trimLeft().startsWith('<')) {
      throw const FormatException('地址返回了 HTML，请提供原始 .txt 地址或 PRTS 剧情页');
    }
    return StoryDocument(
      title: title ?? uri.pathSegments.last,
      script: StoryScript.parse(text),
    );
  }

  Uri _entryUri(StoryEntry entry) {
    final uri = Uri.tryParse(entry.path);
    if (uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'prts.wiki' &&
        uri.path.startsWith('/w/')) {
      return _wikiApiUri(uri.path.substring(3));
    }
    return storyBase.resolve('${entry.path}.txt');
  }

  Future<StoryDocument> loadEntry(StoryEntry entry) =>
      load(_entryUri(entry), title: entry.title);

  List<StoryGroup> _parseGameplayIndex(String source) {
    final document = html.parse(source);
    final table = document
        .querySelectorAll('table')
        .where(
          (table) => table
              .querySelectorAll('th')
              .any((th) => th.text.trim() == '活动剧情一览'),
        )
        .firstOrNull;
    if (table == null) throw const FormatException('未找到活动剧情一览');
    final groups = <StoryGroup>[];
    String? section;
    var remaining = 0;
    for (final row in table.querySelectorAll('tr')) {
      final cells = row.children;
      final headers = cells.where((cell) => cell.localName == 'th').toList();
      final values = cells.where((cell) => cell.localName == 'td').toList();
      if (headers.isEmpty || values.isEmpty) continue;
      final first = headers.first;
      final span = int.tryParse(first.attributes['rowspan'] ?? '');
      if (span != null) {
        section = first.text.trim();
        remaining = span;
      }
      if (remaining > 0 && {'特殊', '四月辑录', '集成战略'}.contains(section)) {
        final name = headers.last.text.trim();
        final groupName = name == '剧情' ? section! : name;
        final entries = <StoryEntry>[];
        for (final link in values.first.querySelectorAll('a[href]')) {
          final title = link.text.trim();
          final uri = gameplayIndexUri.resolve(link.attributes['href']!);
          if (title.isEmpty ||
              uri.scheme != 'https' ||
              uri.host != 'prts.wiki' ||
              !uri.path.startsWith('/w/')) {
            continue;
          }
          entries.add(StoryEntry(title, uri.toString(), name: title));
        }
        if (entries.isNotEmpty) {
          groups.add(
            StoryGroup(
              groupName,
              entries,
              id: _gameplayIds[groupName] ?? groupName,
              entryType: 'GAMEPLAY',
            ),
          );
        }
      }
      if (remaining > 0) remaining--;
      if (remaining == 0) section = null;
    }
    if (groups.isEmpty) throw const FormatException('活动剧情一览没有玩法剧情');
    return groups;
  }

  Future<List<StoryGroup>> _loadGameplayIndex() async {
    try {
      final bytes = await store.fetchRemote(gameplayIndexUri);
      final groups = _parseGameplayIndex(_wikiApiHtml(utf8.decode(bytes)));
      try {
        await store.writeCache(gameplayIndexUri, bytes);
      } catch (_) {}
      return groups;
    } catch (_) {
      final cached = await store.readCache(gameplayIndexUri);
      if (cached == null) return [];
      try {
        return _parseGameplayIndex(_wikiApiHtml(utf8.decode(cached)));
      } catch (_) {
        return [];
      }
    }
  }

  /// 目录来自 PRTS 的剧情索引表；播放器组件不关心它的来源。
  Future<List<StoryGroup>> loadIndex() async {
    final groups = jsonDecode(
      utf8.decode(await store.load(indexUri)),
    ) as Map<String, dynamic>;
    final result = <StoryGroup>[];
    for (final group in groups.values) {
      final entries = <StoryEntry>[];
      for (final story in (group['infoUnlockDatas'] as List? ?? const [])) {
        final path = story['storyTxt']?.toString() ?? '';
        // storyCanShow 只表示游戏内“剧情回顾”是否列出该条目：主线与干员密录在该处恒为 0。
        // 存档播放不依赖它，因此只按 storyTxt 是否可用过滤。
        if (path.isEmpty) continue;
        final label = [
          story['storyCode'],
          story['storyName'],
          story['avgTag'],
        ].where((s) => s != null && s.toString().isNotEmpty).join(' ');
        entries.add(
          StoryEntry(
            label,
            path,
            code: story['storyCode']?.toString() ?? '',
            name: story['storyName']?.toString() ?? '',
            tag: story['avgTag']?.toString() ?? '',
          ),
        );
      }
      if (entries.isNotEmpty) {
        result.add(
          StoryGroup(
            group['name']?.toString() ?? '${group['id']}',
            entries,
            id: group['id']?.toString() ?? '',
            entryType: group['entryType']?.toString() ?? 'NONE',
          ),
        );
      }
    }
    return [...result, ...await _loadGameplayIndex()];
  }

  Future<PreparedStory> prepare(
    StoryDocument document, {
    void Function(int, int)? onProgress,
  }) async {
    final catalog = await MediaCatalog.load(store);
    final warnings = <String>[];
    final assets = catalog.dependencies(document.script, warnings);
    warnings.addAll(await store.preload(assets, onProgress: onProgress));
    return PreparedStory(document, catalog, store, warnings);
  }
}

class PreparedStory {
  const PreparedStory(this.document, this.catalog, this.assets, this.warnings);
  final StoryDocument document;
  final MediaCatalog catalog;
  final AssetStore assets;
  final List<String> warnings;
}
