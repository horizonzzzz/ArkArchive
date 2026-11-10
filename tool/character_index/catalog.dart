import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'package:arknights_story_player/story_player/script.dart';

const professions = <String, String>{
  'PIONEER': '先锋',
  'WARRIOR': '近卫',
  'TANK': '重装',
  'SNIPER': '狙击',
  'CASTER': '术师',
  'MEDIC': '医疗',
  'SUPPORT': '辅助',
  'SPECIAL': '特种',
};

Map<String, dynamic> object(Object? value, String context) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$context 必须是 JSON 对象');
  }
  return value;
}

List<dynamic> array(Object? value, String context) {
  if (value is! List) throw FormatException('$context 必须是 JSON 数组');
  return value;
}

String normalizedName(String value) =>
    value.trim().replaceAll('（', '(').replaceAll('）', ')');

String detailFilename(String id) {
  if (!RegExp(r'^(op:char_[a-zA-Z0-9_]+|npc:[a-zA-Z0-9_%.-]+)$').hasMatch(id)) {
    throw FormatException('不安全的人物 ID：$id');
  }
  return '${id.replaceFirst(':', '_')}.json';
}

Uri mediaUri(String filename, {int? width}) {
  final hash = md5.convert(utf8.encode(filename)).toString();
  final segments = [
    if (width != null) 'thumb',
    hash[0],
    hash.substring(0, 2),
    filename,
    if (width != null) '${width}px-$filename',
  ];
  return Uri(scheme: 'https', host: 'media.prts.wiki', pathSegments: segments);
}

class ArchivePerson {
  ArchivePerson({
    required this.id,
    required this.kind,
    required this.name,
    this.appellation = '',
    this.faction = '',
  });

  final String id;
  final String kind;
  final String name;
  final String appellation;
  final String faction;
  final Set<String> aliases = {};
  final List<Map<String, dynamic>> forms = [];
  final List<Map<String, dynamic>> profile = [];
  final List<Map<String, dynamic>> artCandidates = [];
  final List<Map<String, dynamic>> appearances = [];

  int get lineCount => appearances.fold(
    0,
    (sum, appearance) => sum + (appearance['lineCount'] as int),
  );

  Map<String, dynamic> toIndex() => {
    'id': id,
    'kind': kind,
    'name': name,
    'appellation': appellation,
    'aliases': aliases.toList()..sort(),
    'faction': faction,
    if (forms.isNotEmpty) 'class': forms.first['class'],
    if (forms.isNotEmpty) 'rarity': forms.first['rarity'],
    'forms': forms,
    'firstStory': appearances.firstOrNull?['story'],
    'storyCount': appearances.length,
    'lineCount': lineCount,
    'searchText': {
      name,
      appellation,
      ...aliases,
      faction,
      ...forms.map((form) => form['class'] as String),
    }.join(' ').toLowerCase(),
    'detailFile': detailFilename(id),
  };

  Map<String, dynamic> toDetail() => {
    'id': id,
    'profile': profile,
    'artCandidates': artCandidates,
    'appearances': appearances,
  };
}

/// 构建期复用播放器解析器；不依赖 Flutter 或运行时缓存。
class CharacterCatalog {
  final Map<String, ArchivePerson> people = {};
  final Map<String, String> _speakerIds = {};
  final Map<String, Map<String, dynamic>> stories = {};
  final Map<String, Map<String, dynamic>> unmatched = {};
  final Map<String, int> speakerLines = {};
  final List<Map<String, dynamic>> excludedNpcs = [];
  final List<Map<String, dynamic>> mergeCandidates = [];
  final List<String> npcOperatorOverlaps = [];
  final Set<String> blocklist = {};
  final Set<String> _processedStories = {};
  int namedLines = 0;
  int matchedLines = 0;
  int blockedLines = 0;
  int formMergeCount = 0;
  int patchFormCount = 0;
  int duplicateStoryEntries = 0;

  void _register(String alias, String id) {
    alias = normalizedName(alias);
    if (alias.isEmpty) throw const FormatException('别名不得为空');
    final previous = _speakerIds[alias];
    if (previous != null && previous != id) {
      throw FormatException('人物称呼冲突：$alias 同时指向 $previous 和 $id');
    }
    _speakerIds[alias] = id;
    if (alias != people[id]!.name) people[id]!.aliases.add(alias);
  }

  void loadOperators({
    required Map<String, dynamic> characters,
    required Map<String, dynamic> patches,
    required Map<String, dynamic> handbook,
    required List<dynamic> merges,
  }) {
    final units = <String, Map<String, dynamic>>{};
    for (final entry in characters.entries) {
      final unit = object(entry.value, entry.key);
      if (unit['isNotObtainable'] == false &&
          professions.containsKey(unit['profession'])) {
        units[entry.key] = unit;
      }
    }
    if (units.isEmpty) throw const FormatException('未找到可获取干员');
    final parents = <String, String>{};
    final patchUnits = object(patches['patchChars'], 'patchChars');
    for (final entry in object(patches['infos'], 'patch infos').entries) {
      if (!units.containsKey(entry.key)) {
        throw FormatException('形态所属干员不存在：${entry.key}');
      }
      final info = object(entry.value, 'patch info ${entry.key}');
      for (final id in array(info['tmplIds'], 'tmplIds').cast<String>()) {
        if (id == entry.key) continue;
        if (units.containsKey(id) || parents.containsKey(id)) {
          throw FormatException('重复的 patch 形态：$id');
        }
        units[id] = object(patchUnits[id], 'patch $id');
        parents[id] = entry.key;
        patchFormCount++;
      }
    }
    for (final value in merges) {
      final merge = object(value, 'form_merge');
      final base = merge['base'];
      final alt = merge['alt'];
      if (base is! String ||
          alt is! String ||
          base == alt ||
          !units.containsKey(base) ||
          !units.containsKey(alt) ||
          parents.containsKey(alt)) {
        throw FormatException('无效或重复的异格合并：$base ← $alt');
      }
      // 只接受一层明确归属，拒绝循环和依赖表顺序的链式合并。
      if (parents.containsKey(base) || parents.containsValue(alt)) {
        throw FormatException('异格合并不得成链或成环：$base ← $alt');
      }
      parents[alt] = base;
      formMergeCount++;
    }
    final profiles = object(handbook['handbookDict'], 'handbookDict');
    for (final entry in units.entries) {
      if (parents.containsKey(entry.key)) continue;
      final unit = entry.value;
      final name = normalizedName(unit['name'] as String);
      final id = 'op:${entry.key}';
      people[id] = ArchivePerson(
        id: id,
        kind: 'operator',
        name: name,
        appellation: unit['appellation'] as String? ?? '',
        faction: (unit['teamId'] ?? unit['groupId'] ?? unit['nationId'] ?? '')
            .toString(),
      );
    }
    for (final entry in units.entries) {
      final base = parents[entry.key] ?? entry.key;
      final person = people['op:$base']!;
      final unit = entry.value;
      final profession = professions[unit['profession']];
      final rarity = int.tryParse(
        '${unit['rarity']}'.replaceFirst('TIER_', ''),
      );
      if (profession == null || rarity == null || rarity < 1 || rarity > 6) {
        throw FormatException('干员职业或星级无效：${entry.key}');
      }
      final isPatch = patchUnits.containsKey(entry.key);
      final name = normalizedName(unit['name'] as String);
      final displayName = isPatch ? '$name($profession)' : name;
      person.forms.add({
        'id': entry.key,
        'label': displayName,
        'class': profession,
        'rarity': rarity,
      });
      _register(name, person.id);
      _register(displayName, person.id);
      // 英文名只用于搜索，不据此推断剧情说话人身份。
      final appellation = unit['appellation'] as String? ?? '';
      if (appellation.isNotEmpty && appellation != person.appellation) {
        person.aliases.add(appellation);
      }
      person.artCandidates.addAll([
        for (final (suffix, kind) in [
          ('', 'avatar'),
          ('_1', 'elite0'),
          ('_2', 'elite2'),
        ])
          {
            'formId': entry.key,
            'kind': kind,
            'url': mediaUri(
              '${kind == 'avatar' ? '头像' : '立绘'}_$displayName$suffix.png',
            ).toString(),
            'verified': false,
            'spoiler': entry.key != base || kind == 'elite2',
          },
      ]);
      final profile = profiles[entry.key];
      if (profile != null) {
        _loadProfile(
          person,
          entry.key,
          object(profile, 'handbook ${entry.key}'),
        );
      }
    }
    // 标准形态始终排首位，避免上游 JSON 的 key 顺序改变默认展示。
    for (final person in people.values) {
      final base = person.id.substring(3);
      final index = person.forms.indexWhere((form) => form['id'] == base);
      if (index > 0) person.forms.insert(0, person.forms.removeAt(index));
    }
    _findMergeCandidates(units, parents);
  }

  void _loadProfile(
    ArchivePerson person,
    String formId,
    Map<String, dynamic> source,
  ) {
    for (final value in array(source['storyTextAudio'], 'storyTextAudio')) {
      final section = object(value, '档案章节');
      for (final value in array(section['stories'], 'stories')) {
        final story = object(value, '档案正文');
        final text = story['storyText'] as String? ?? '';
        if (text.trim().isEmpty) continue;
        person.profile.add({
          'formId': formId,
          'title': section['storyTitle'] as String? ?? '',
          'text': text,
          'spoiler': story['unLockType'] != 'DIRECT',
          if (story['patchIdList'] != null) 'formIds': story['patchIdList'],
        });
      }
    }
  }

  void _findMergeCandidates(
    Map<String, Map<String, dynamic>> units,
    Map<String, String> parents,
  ) {
    final englishIds = <String, List<String>>{};
    for (final entry in units.entries) {
      final name = '${entry.value['appellation']}'.toLowerCase();
      englishIds.putIfAbsent(name, () => []).add(entry.key);
    }
    for (final entry in units.entries) {
      if (parents.containsKey(entry.key)) continue;
      final name = '${entry.value['appellation']}'.toLowerCase();
      final position = name.indexOf(' the ');
      if (position < 1) continue;
      final candidates = englishIds[name.substring(0, position)] ?? [];
      for (final base in candidates.where((id) => id != entry.key)) {
        mergeCandidates.add({
          'base': base,
          'alt': entry.key,
          'name': entry.value['name'],
          'reason': '英文名 the 模式，仅提示，不自动合并',
        });
      }
    }
  }

  Element? _tableOf(Element element) {
    for (var parent = element.parent; parent != null; parent = parent.parent) {
      if (parent.localName == 'table') return parent;
    }
    return null;
  }

  void loadNpcs(String source) {
    final document = html.parse(source);
    var rowsFound = 0;
    for (final table in document.querySelectorAll('table')) {
      if (!table
          .querySelectorAll('th')
          .any(
            (cell) => cell.text.trim() == '名称/代号' && _tableOf(cell) == table,
          )) {
        continue;
      }
      for (final row in table.querySelectorAll('tr')) {
        if (_tableOf(row) != table) continue;
        final cells = row.children
            .where((cell) => cell.localName == 'td')
            .toList();
        if (cells.length != 4) continue;
        final name = normalizedName(cells[0].text);
        if (name.isEmpty) continue;
        rowsFound++;
        if (blocklist.contains(name) ||
            RegExp(r'^[？?]+$|的(?:父母|父亲|母亲)$').hasMatch(name) ||
            name == '占位符') {
          excludedNpcs.add({'name': name, 'reason': '占位、群体或排除表'});
          continue;
        }
        if (_speakerIds[name]?.startsWith('op:') == true) {
          npcOperatorOverlaps.add(name);
          continue;
        }
        final slug = Uri.encodeComponent(name).replaceAllMapped(
          RegExp(r"[!'()*~]"),
          (match) =>
              '%${match[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}',
        );
        final id = 'npc:$slug';
        final person = people.putIfAbsent(
          id,
          () => ArchivePerson(id: id, kind: 'npc', name: name),
        );
        _register(name, id);
        final text = cells[1].text.trim();
        if (text.isNotEmpty &&
            !person.profile.any((section) => section['text'] == text)) {
          // Wiki 简介常直接揭示结局，不能作为无剧透的基础档案。
          person.profile.add({
            'title': '人物简介',
            'text': text,
            'spoiler': true,
            'source': cells[2].text.trim(),
          });
        }
        for (final image in cells[3].querySelectorAll('img[src]')) {
          final uri = Uri.tryParse(image.attributes['src']!);
          if (uri == null ||
              uri.scheme != 'https' ||
              uri.host != 'media.prts.wiki') {
            continue;
          }
          final segments = uri.pathSegments;
          final filename =
              segments.firstOrNull == 'thumb' && segments.length >= 4
              ? segments[3]
              : segments.lastOrNull ?? '';
          if (!filename.startsWith('Avg_') || !filename.endsWith('.png')) {
            continue;
          }
          final url = mediaUri(filename).toString();
          if (person.artCandidates.any((art) => art['url'] == url)) continue;
          person.artCandidates.add({
            'kind': 'avg',
            'url': url,
            'verified': false,
            'spoiler': true,
          });
        }
      }
    }
    if (rowsFound == 0) throw const FormatException('未找到剧情角色一览的四列人物表');
  }

  void loadAliases(Map<String, dynamic> aliases) {
    for (final entry in aliases.entries) {
      final id = entry.value;
      if (id is! String || !people.containsKey(id)) {
        throw FormatException('别名指向不存在的人物：${entry.key} → $id');
      }
      if (blocklist.contains(normalizedName(entry.key))) {
        throw FormatException('别名与排除表冲突：${entry.key}');
      }
      _register(entry.key, id);
    }
  }

  void loadStories(Map<String, dynamic> source) {
    var order = 0;
    for (final value in source.values) {
      final group = object(value, '剧情分组');
      for (final value in array(group['infoUnlockDatas'], 'infoUnlockDatas')) {
        final story = object(value, '剧情条目');
        final path = story['storyTxt'] as String? ?? '';
        if (path.isEmpty) continue;
        if (!RegExp(r'^[a-zA-Z0-9_/-]+$').hasMatch(path) ||
            path
                .split('/')
                .any((segment) => segment.isEmpty || segment == '..')) {
          throw FormatException('不安全的剧情路径：$path');
        }
        if (stories.containsKey(path)) {
          duplicateStoryEntries++;
          continue;
        }
        stories[path] = {
          'group': group['entryType'],
          'chapter': group['name'],
          'code': story['storyCode'] ?? '',
          'name': story['storyName'] ?? '',
          'tag': story['avgTag'] ?? '',
          'order': order++,
        };
      }
    }
    if (stories.isEmpty) throw const FormatException('剧情目录为空');
  }

  void scanStory(String path, List<int> bytes) {
    final metadata = stories[path];
    if (metadata == null) throw FormatException('剧情不在目录中：$path');
    if (_processedStories.contains(path)) throw FormatException('重复扫描剧情：$path');
    final script = StoryScript.parse(utf8.decode(bytes));
    metadata['scriptHash'] = sha256.convert(bytes).toString();
    final perPerson = <String, List<Map<String, dynamic>>>{};
    for (var index = 0; index < script.commands.length; index++) {
      final command = script.commands[index];
      if (command.tag != 'dialogue' || command.text.trim().isEmpty) continue;
      final name = normalizedName(command.value('name'));
      if (name.isEmpty) continue;
      namedLines++;
      speakerLines.update(name, (value) => value + 1, ifAbsent: () => 1);
      if (blocklist.contains(name)) {
        blockedLines++;
        continue;
      }
      final id = _speakerIds[name];
      if (id == null) {
        final item = unmatched.putIfAbsent(
          name,
          () => {
            'name': name,
            'lineCount': 0,
            'sampleStory': path,
            'sampleText': command.text,
          },
        );
        item['lineCount'] = (item['lineCount'] as int) + 1;
        continue;
      }
      matchedLines++;
      perPerson.putIfAbsent(id, () => []).add({
        'commandIndex': index,
        'line': command.line,
        'speaker': name,
        'text': command.text,
      });
    }
    for (final entry in perPerson.entries) {
      final lines = entry.value;
      final interior = lines
          .skip(1)
          .take(lines.length > 2 ? lines.length - 2 : 0);
      final longest = interior.isEmpty
          ? null
          : interior.reduce(
              (a, b) =>
                  (b['text'] as String).runes.length >=
                      (a['text'] as String).runes.length
                  ? b
                  : a,
            );
      final snippets = {lines.first, lines.last, ?longest}.toList()
        ..sort(
          (a, b) =>
              (a['commandIndex'] as int).compareTo(b['commandIndex'] as int),
        );
      people[entry.key]!.appearances.add({
        'story': path,
        'lineCount': lines.length,
        'snippets': snippets,
      });
    }
    _processedStories.add(path);
  }

  void sortAppearances() {
    for (final person in people.values) {
      person.appearances.sort(
        (a, b) => (stories[a['story']]!['order'] as int).compareTo(
          stories[b['story']]!['order'] as int,
        ),
      );
    }
  }

  List<Map<String, dynamic>> get includedPeople =>
      people.values
          .where((person) => person.profile.isNotEmpty || person.lineCount > 0)
          .map((person) => person.toIndex())
          .toList()
        ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));

  List<Map<String, dynamic>> get unmatchedSpeakers =>
      unmatched.values.toList()..sort((a, b) {
        final count = (b['lineCount'] as int).compareTo(a['lineCount'] as int);
        return count != 0
            ? count
            : (a['name'] as String).compareTo(b['name'] as String);
      });

  Map<String, dynamic> statistics() {
    final top = speakerLines.entries.toList()
      ..sort((a, b) {
        final count = b.value.compareTo(a.value);
        return count != 0 ? count : a.key.compareTo(b.key);
      });
    final top200 = top.take(200);
    final topLines = top200.fold(0, (sum, item) => sum + item.value);
    final topMatched = top200
        .where(
          (item) =>
              !blocklist.contains(item.key) &&
              _speakerIds.containsKey(item.key),
        )
        .fold(0, (sum, item) => sum + item.value);
    return {
      'people': includedPeople.length,
      'operators': includedPeople
          .where((person) => person['kind'] == 'operator')
          .length,
      'npcs': includedPeople.where((person) => person['kind'] == 'npc').length,
      'forms': people.values.fold(
        0,
        (sum, person) => sum + person.forms.length,
      ),
      'manualFormMerges': formMergeCount,
      'officialPatchForms': patchFormCount,
      'expectedStories': stories.length,
      'scannedStories': _processedStories.length,
      'duplicateStoryEntries': duplicateStoryEntries,
      'namedLines': namedLines,
      'matchedLines': matchedLines,
      'blockedLines': blockedLines,
      'unmatchedLines': namedLines - matchedLines - blockedLines,
      'unmatchedSpeakers': unmatched.length,
      'namedLineCoverage': namedLines == 0 ? null : matchedLines / namedLines,
      'top200NamedLineCoverage': topLines == 0 ? null : topMatched / topLines,
      'artVerification': 'not_run',
    };
  }
}

String csvCell(Object? value) {
  var text = value?.toString() ?? '';
  if (RegExp(r'^[=+@\-\t\r]').hasMatch(text)) text = "'$text";
  return '"${text.replaceAll('"', '""')}"';
}

String unmatchedCsv(List<Map<String, dynamic>> rows) => [
  'name,lineCount,sampleStory,sampleText,candidate,confidence',
  for (final row in rows)
    [
      row['name'],
      row['lineCount'],
      row['sampleStory'],
      row['sampleText'],
      '',
      '',
    ].map(csvCell).join(','),
  '',
].join('\r\n');
