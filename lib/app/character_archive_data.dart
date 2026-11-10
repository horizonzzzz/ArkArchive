import 'dart:convert';

import 'package:flutter/services.dart';

import 'character_archive_paths.dart';

String normalizeCharacterQuery(String value) =>
    value.trim().toLowerCase().replaceAll('（', '(').replaceAll('）', ')');

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('人物档案结构无效');
  }
  return value;
}

List<Map<String, dynamic>> _objects(Object? value) =>
    (value as List? ?? const []).map(_object).toList();
List<String> _strings(Object? value) =>
    (value as List? ?? const []).cast<String>();
String _text(Map<String, dynamic> json, String key) =>
    json[key] as String? ?? '';
int _integer(Map<String, dynamic> json, String key) =>
    (json[key] as num?)?.toInt() ?? 0;

typedef CharacterReplay = Future<void> Function(
  CharacterStory story,
  CharacterSnippet snippet,
);

enum CharacterOrder { appearances, firstAppearance, name, rarity }

class CharacterForm {
  CharacterForm.fromJson(Map<String, dynamic> json)
    : id = _text(json, 'id'),
      name = _text(json, 'name'),
      profession = _text(json, 'class'),
      rarity = _integer(json, 'rarity');
  final String id, name, profession;
  final int rarity;
}

class CharacterSummary {
  CharacterSummary.fromJson(Map<String, dynamic> json)
    : id = _text(json, 'id'),
      name = _text(json, 'name'),
      kind = _text(json, 'kind'),
      appellation = _text(json, 'appellation'),
      aliases = _strings(json['aliases']),
      faction = _text(json, 'faction'),
      profession = _text(json, 'class'),
      rarity = _integer(json, 'rarity'),
      forms = _objects(json['forms']).map(CharacterForm.fromJson).toList(),
      thumbnailUrl = _text(json, 'thumbnailUrl'),
      portraitUrl = _text(json, 'portraitUrl'),
      firstStory = _text(json, 'firstStory'),
      storyCount = _integer(json, 'storyCount'),
      lineCount = _integer(json, 'lineCount'),
      detailFile = _text(json, 'detailFile') {
    if (detailFile != characterDetailFilename(id)) {
      throw const FormatException('人物详情引用无效');
    }
  }

  final String id, name, kind, appellation, faction, profession;
  final String thumbnailUrl, portraitUrl, firstStory, detailFile;
  final List<String> aliases;
  final List<CharacterForm> forms;
  final int rarity, storyCount, lineCount;
  bool get isOperator => kind == 'operator';

  int searchRank(String query) {
    final q = normalizeCharacterQuery(query);
    if (q.isEmpty) return 0;
    final primary = normalizeCharacterQuery(name);
    final names = [
      appellation,
      ...aliases,
      ...forms.map((f) => f.name),
    ].map(normalizeCharacterQuery).where((name) => name.isNotEmpty).toList();
    if (primary == q) return 4;
    if (names.contains(q)) return 3;
    if ([primary, ...names].any((name) => name.startsWith(q))) return 2;
    final metadata = [
      primary,
      ...names,
      faction,
      profession,
      ...forms.map((f) => f.profession),
    ].join(' ').toLowerCase();
    return metadata.contains(q) ? 1 : -1;
  }
}

class CharacterStory {
  CharacterStory(this.path, Map<String, dynamic> json)
    : chapter = _text(json, 'chapter'),
      code = _text(json, 'code'),
      name = _text(json, 'name'),
      tag = _text(json, 'tag'),
      scriptHash = _text(json, 'scriptHash'),
      order = _integer(json, 'order');
  final String path, chapter, code, name, tag, scriptHash;
  final int order;
  String get title => [code, name, tag].where((s) => s.isNotEmpty).join(' · ');
}

class CharacterIndex {
  CharacterIndex.fromJson(Map<String, dynamic> json)
    : people = _objects(json['people']).map(CharacterSummary.fromJson).toList(),
      stories = _object(
        json['stories'],
      ).map((key, value) => MapEntry(key, CharacterStory(key, _object(value)))),
      version = _text(json, 'version'),
      generatedAt = DateTime.tryParse(_text(json, 'generatedAt')) {
    if (json['schema'] != 1 || _object(json['coverage'])['complete'] != true) {
      throw const FormatException('人物档案版本不支持或数据不完整');
    }
  }
  final List<CharacterSummary> people;
  final Map<String, CharacterStory> stories;
  final String version;
  final DateTime? generatedAt;

  List<CharacterSummary> search({
    String query = '',
    String kind = '',
    String profession = '',
    String faction = '',
    int? rarity,
    CharacterOrder order = CharacterOrder.appearances,
  }) {
    final ranks = <String, int>{};
    final result = people.where((person) {
      if (kind.isNotEmpty && person.kind != kind) return false;
      if (faction.isNotEmpty && person.faction != faction) return false;
      if ((profession.isNotEmpty || rarity != null) &&
          !person.forms.any(
            (form) =>
                (profession.isEmpty || form.profession == profession) &&
                (rarity == null || form.rarity == rarity),
          )) {
        return false;
      }
      ranks[person.id] = person.searchRank(query);
      return ranks[person.id]! >= 0;
    }).toList();
    int first(CharacterSummary p) => stories[p.firstStory]?.order ?? 0x7fffffff;
    result.sort((a, b) {
      final relevance = ranks[b.id]!.compareTo(ranks[a.id]!);
      if (relevance != 0) return relevance;
      final compared = switch (order) {
        CharacterOrder.appearances => b.storyCount.compareTo(a.storyCount),
        CharacterOrder.firstAppearance => first(a).compareTo(first(b)),
        CharacterOrder.name => a.name.compareTo(b.name),
        CharacterOrder.rarity => b.rarity.compareTo(a.rarity),
      };
      if (compared != 0) return compared;
      final lines = b.lineCount.compareTo(a.lineCount);
      if (lines != 0) return lines;
      final earliest = first(a).compareTo(first(b));
      return earliest != 0 ? earliest : a.id.compareTo(b.id);
    });
    return result;
  }
}

class CharacterProfile {
  CharacterProfile.fromJson(Map<String, dynamic> json)
    : title = _text(json, 'title'),
      text = _text(json, 'text'),
      formId = _text(json, 'formId'),
      formIds = _strings(json['formIds']),
      spoiler = json['spoiler'] != false;
  final String title, text, formId;
  final List<String> formIds;
  final bool spoiler;
  bool appliesTo(String id) => formIds.isNotEmpty
      ? formIds.contains(id)
      : formId.isEmpty || formId == id;
}

class CharacterArtwork {
  CharacterArtwork.fromJson(Map<String, dynamic> json)
    : url = _text(json, 'url'),
      kind = _text(json, 'kind'),
      formId = _text(json, 'formId'),
      spoiler = json['spoiler'] != false;
  final String url, kind, formId;
  final bool spoiler;
  String get label => switch (kind) {
    'elite0' => '基础立绘',
    'elite2' => '精英二立绘',
    'avatar' => '头像',
    _ => '剧情立绘',
  };
}

class CharacterSnippet {
  CharacterSnippet.fromJson(Map<String, dynamic> json)
    : commandIndex = _integer(json, 'commandIndex'),
      line = _integer(json, 'line'),
      speaker = _text(json, 'speaker'),
      text = _text(json, 'text');
  final int commandIndex, line;
  final String speaker, text;
}

class CharacterAppearance {
  CharacterAppearance.fromJson(Map<String, dynamic> json)
    : story = _text(json, 'story'),
      lineCount = _integer(json, 'lineCount'),
      snippets = _objects(json['snippets'])
          .map(CharacterSnippet.fromJson)
          .toList();
  final String story;
  final int lineCount;
  final List<CharacterSnippet> snippets;
}

class CharacterDetail {
  CharacterDetail.fromJson(Map<String, dynamic> json)
    : id = _text(json, 'id'),
      profile = _objects(json['profile'])
          .map(CharacterProfile.fromJson)
          .toList(),
      artwork = _objects(json['artCandidates'])
          .where((a) => a['verified'] == true)
          .map(CharacterArtwork.fromJson)
          .toList(),
      appearances = _objects(json['appearances'])
          .map(CharacterAppearance.fromJson)
          .toList();
  final String id;
  final List<CharacterProfile> profile;
  final List<CharacterArtwork> artwork;
  final List<CharacterAppearance> appearances;
}

/// 首版读取随包发布的快照；图片由 AssetStore 的共享缓存单独管理。
class CharacterRepository {
  CharacterRepository({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;
  final AssetBundle _bundle;
  Future<CharacterIndex>? _index;
  final Map<String, Future<CharacterDetail>> _details = {};

  Future<CharacterIndex> loadIndex({bool reload = false}) {
    if (reload) _index = null;
    return _index ??= _read('index.json').then(CharacterIndex.fromJson);
  }

  Future<CharacterDetail> loadDetail(
    CharacterSummary person, {
    bool reload = false,
  }) {
    if (reload) _details.remove(person.id);
    if (_details.length >= 12 && !_details.containsKey(person.id)) {
      _details.remove(_details.keys.first);
    }
    return _details.putIfAbsent(person.id, () async {
      final detail = CharacterDetail.fromJson(
        await _read('details/${person.detailFile}'),
      );
      if (detail.id != person.id) throw const FormatException('人物详情与索引不匹配');
      return detail;
    });
  }

  Future<Map<String, dynamic>> _read(String name) async =>
      _object(jsonDecode(await _bundle.loadString('assets/characters/$name')));
}
