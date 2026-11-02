import 'dart:convert';
import 'package:html/parser.dart' as html;
import '../script.dart';
import 'asset_store.dart';
import 'media_catalog.dart';

class StoryDocument {
  const StoryDocument({required this.title, required this.script});
  final String title;
  final StoryScript script;
}

class StoryEntry {
  const StoryEntry(this.title, this.path);
  final String title;
  final String path;
}

class StoryGroup {
  const StoryGroup(this.name, this.entries);
  final String name;
  final List<StoryEntry> entries;
}

class StoryRepository {
  StoryRepository(this.store);
  final AssetStore store;
  /// PRTS 静态数据站同时提供剧情索引和原始脚本，Web 端也允许跨域读取。
  static final indexUri = Uri.parse('https://torappu.prts.wiki/gamedata/latest/excel/story_review_table.json');
  static final storyBase = Uri.parse('https://torappu.prts.wiki/gamedata/latest/story/');

  Future<StoryDocument> load(Uri uri, {String? title}) async {
    final text = utf8.decode(await store.load(uri));
    if (uri.host == 'prts.wiki' || uri.host == 'www.prts.wiki') {
      final page = html.parse(text);
      final script = page.querySelector('#datas_txt')?.text;
      if (script == null || script.trim().isEmpty) throw const FormatException('页面没有 #datas_txt 剧情脚本');
      return StoryDocument(title: title ?? page.querySelector('#firstHeading')?.text.trim() ?? uri.path, script: StoryScript.parse(script));
    }
    if (text.trimLeft().startsWith('<')) throw const FormatException('地址返回了 HTML，请提供原始 .txt 地址或 PRTS 剧情页');
    return StoryDocument(title: title ?? uri.pathSegments.last, script: StoryScript.parse(text));
  }

  Future<StoryDocument> loadEntry(StoryEntry entry) => load(storyBase.resolve('${entry.path}.txt'), title: entry.title);

  /// 目录来自 PRTS 的剧情索引表；播放器组件不关心它的来源。
  Future<List<StoryGroup>> loadIndex() async {
    final groups = jsonDecode(utf8.decode(await store.load(indexUri))) as Map<String, dynamic>;
    final result = <StoryGroup>[];
    for (final group in groups.values) {
      final entries = <StoryEntry>[];
      for (final story in (group['infoUnlockDatas'] as List? ?? const [])) {
        final path = story['storyTxt']?.toString() ?? '';
        if (path.isEmpty || story['storyCanShow'] != 1) continue;
        final label = [story['storyCode'], story['storyName'], story['avgTag']].where((s) => s != null && s.toString().isNotEmpty).join(' ');
        entries.add(StoryEntry(label, path));
      }
      if (entries.isNotEmpty) result.add(StoryGroup(group['name']?.toString() ?? '${group['id']}', entries));
    }
    return result;
  }

  Future<PreparedStory> prepare(StoryDocument document, {void Function(int, int)? onProgress}) async {
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
