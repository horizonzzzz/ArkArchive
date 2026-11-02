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

class StoryRepository {
  StoryRepository(this.store);
  final AssetStore store;
  static final storyBase = Uri.parse('https://raw.githubusercontent.com/Kengxxiao/ArknightsGameData/master/zh_CN/gamedata/story/');

  Future<StoryDocument> load(Uri uri) async {
    final text = utf8.decode(await store.load(uri));
    if (uri.host == 'prts.wiki' || uri.host == 'www.prts.wiki') {
      final page = html.parse(text);
      final script = page.querySelector('#datas_txt')?.text;
      if (script == null || script.trim().isEmpty) throw const FormatException('页面没有 #datas_txt 剧情脚本');
      return StoryDocument(title: page.querySelector('#firstHeading')?.text.trim() ?? uri.path, script: StoryScript.parse(script));
    }
    if (text.trimLeft().startsWith('<')) throw const FormatException('地址返回了 HTML，请提供原始 .txt 地址或 PRTS 剧情页');
    return StoryDocument(title: uri.pathSegments.last, script: StoryScript.parse(text));
  }

  /// 供后续关卡选择页使用，目录不进入播放器组件。
  Future<List<StoryEntry>> loadIndex() async {
    final uri = Uri.parse('https://raw.githubusercontent.com/Kengxxiao/ArknightsGameData/master/zh_CN/gamedata/excel/story_review_table.json');
    final groups = jsonDecode(utf8.decode(await store.load(uri))) as Map<String, dynamic>;
    final entries = <StoryEntry>[];
    for (final group in groups.values) {
      for (final story in (group['infoUnlockDatas'] as List? ?? [])) {
        final path = story['storyTxt']?.toString() ?? '';
        if (path.isNotEmpty) entries.add(StoryEntry([story['storyCode'], story['storyName'], story['avgTag']].where((s) => s != null && s.toString().isNotEmpty).join(' · '), path));
      }
    }
    return entries;
  }

  Future<PreparedStory> prepare(StoryDocument document, {void Function(int, int)? onProgress}) async {
    final catalog = await MediaCatalog.load(store);
    final warnings = <String>[];
    final assets = catalog.dependencies(document.script, warnings);
    assets.add(MediaCatalog.fontUri);
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
