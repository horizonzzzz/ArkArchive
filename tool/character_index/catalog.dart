import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'package:arknights_story_player/app/character_archive_paths.dart';
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

String detailFilename(String id) => characterDetailFilename(id);

/// NPC 人物 ID 与 PRTS 剧情角色一览页的 slug 规则保持一致。
String npcId(String name) {
  final slug = Uri.encodeComponent(name).replaceAllMapped(
    RegExp(r"[!'()*~]"),
    (match) => '%${match[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}',
  );
  return 'npc:$slug';
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

  /// 卡片默认图严格按形态顺序取标准立绘，
  /// 不让 artCandidates 的插入顺序（character_table 键序）影响默认展示。
  Map<String, dynamic>? get portrait {
    for (final form in forms) {
      final base = artCandidates
          .where(
            (art) =>
                art['formId'] == form['id'] &&
                art['kind'] == 'elite0' &&
                art['verified'] == true,
          )
          .firstOrNull;
      if (base != null) return base;
    }
    // 形态顺序全无图时退回任一已验证立绘，有图仍好过文字占位。
    return artCandidates
        .where(
          (art) =>
              art['verified'] == true &&
              (art['kind'] == 'elite0' || art['kind'] == 'avg'),
        )
        .firstOrNull;
  }

  Map<String, dynamic> toIndex() => {
    'id': id,
    'kind': kind,
    'name': name,
    'appellation': appellation,
    'aliases': aliases.toList()..sort(),
    'faction': faction,
    'portraitUrl': portrait?['url'],
    'thumbnailUrl': portrait?['thumbnailUrl'],
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
  // 全部 avg 资源使用统计：key -> {故事篇目 Set、共现说话人计数 Map}。
  // 覆盖已归属与未归属说话人，供构建后生成人工对照表。
  final Map<String, Map<String, dynamic>> avgKeyUsage = {};
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
    Map<String, dynamic> teams = const {},
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
        faction: _factionName(unit, teams),
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
    // 标准形态始终排首位，避免上游 JSON 的 key 顺序改变默认展示；
    // 立绘候选同步重排，保证卡片默认图与详情画廊顺序一致。
    for (final person in people.values) {
      final base = person.id.substring(3);
      final index = person.forms.indexWhere((form) => form['id'] == base);
      if (index > 0) {
        person.forms.insert(0, person.forms.removeAt(index));
        _orderArtCandidates(person);
      }
    }
    _findMergeCandidates(units, parents);
  }

  void _orderArtCandidates(ArchivePerson person) {
    final ordered = <Map<String, dynamic>>[];
    for (final form in person.forms) {
      ordered.addAll(
        person.artCandidates.where((art) => art['formId'] == form['id']),
      );
    }
    // 出现 forms 之外的 formId 属于上游异常，保持原序交由后续校验暴露。
    if (ordered.length != person.artCandidates.length) return;
    person.artCandidates
      ..clear()
      ..addAll(ordered);
  }

  String _factionName(Map<String, dynamic> unit, Map<String, dynamic> teams) {
    final id = unit['teamId'] ?? unit['groupId'] ?? unit['nationId'] ?? '';
    final entry = teams[id];
    return entry is Map
        ? entry['powerName'] as String? ?? id.toString()
        : id.toString();
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
        final id = npcId(name);
        final person = people.putIfAbsent(
          id,
          () => ArchivePerson(id: id, kind: 'npc', name: name),
        );
        _register(name, id);
        final text = cells[1].text.trim();
        if (text.isNotEmpty &&
            !person.profile.any((section) => section['text'] == text)) {
          person.profile.add({
            'title': '人物简介',
            'text': text,
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

  /// 人工收录表：边缘人物建卡与伪装/归属合并。
  /// [groupPatterns] 为群体/职务称呼正则，建卡名单命中即拒绝，防群体误建卡。
  void loadNpcExtras(
    Map<String, dynamic> extras, {
    Set<String> groupPatterns = const {},
  }) {
    final groups = Set<String>.of(groupPatterns);
    for (final entry in extras.entries) {
      final name = normalizedName(entry.key);
      final spec = object(entry.value, 'npc_extra ${entry.key}');
      if (name.isEmpty) throw const FormatException('npc_extra 名不得为空');
      if (blocklist.contains(name)) {
        throw FormatException('npc_extra 名与排除表冲突：$name');
      }
      final mergeInto = spec['mergeInto'] as String?;
      if (mergeInto != null) {
        if (!people.containsKey(mergeInto)) {
          throw FormatException('npc_extra 归并目标不存在：$name → $mergeInto');
        }
        final previous = _speakerIds[name];
        if (previous != null && previous != mergeInto) {
          throw FormatException('人物称呼冲突：$name 已指向 $previous');
        }
        _register(name, mergeInto);
        final aliases = spec['aliases'];
        if (aliases != null) {
          for (final alias in array(
            aliases,
            'npc_extra aliases',
          ).cast<String>()) {
            _register(alias, mergeInto);
          }
        }
        continue;
      }
      for (final pattern in groups) {
        final regex = RegExp(pattern);
        if (regex.hasMatch(name)) {
          throw FormatException('npc_extra 建卡名属于群体称呼：$name（规则：$pattern）');
        }
      }
      final faction = spec['faction'] as String?;
      if (faction != null && faction.isEmpty) {
        throw const FormatException('npc_extra faction 不得为空串');
      }
      final id = npcId(name);
      final person = people.putIfAbsent(
        id,
        () => ArchivePerson(
          id: id,
          kind: 'npc',
          name: name,
          faction: faction ?? '',
        ),
      );
      if (faction != null && faction.isNotEmpty && person.faction.isEmpty) {
        throw FormatException('npc_extra faction 与已有人物不一致：$name');
      }
      _register(name, id);
      final avg = spec['avg'] as String?;
      if (avg != null && avg.isNotEmpty) {
        if (!RegExp(r'^[A-Za-z0-9_$#]+$').hasMatch(avg)) {
          throw FormatException('npc_extra avg 资源名不安全：$avg');
        }
        // 枚举皮肤变体交给图片校验淘汰；复杂资源名（含 #/$）原样即完整文件主体；
        final base = avg.replaceFirst(RegExp(r'_\d+$'), '');
        final variants = <String>{
          avg,
          if (base != avg) '${base}_2',
          if (base != avg) '${base}_3',
          if (base != avg) '${base}_4',
        };
        for (final variant in variants) {
          person.artCandidates.add({
            'kind': 'avg',
            'url': mediaUri('Avg_$variant.png').toString(),
            'verified': false,
          });
        }
      }
      final aliases = spec['aliases'];
      if (aliases != null) {
        for (final alias in array(
          aliases,
          'npc_extra aliases',
        ).cast<String>()) {
          _register(alias, id);
        }
      }
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

  void _touchAvgKey(String key, String story) {
    // char_empty 是清台占位，不是资源。
    if (key == 'char_empty') return;
    final usage = avgKeyUsage.putIfAbsent(
      key,
      () => {'stories': <String>{}, 'speakers': <String, int>{}},
    );
    (usage['stories'] as Set<String>).add(story);
  }

  void scanStory(String path, List<int> bytes) {
    final metadata = stories[path];
    if (metadata == null) throw FormatException('剧情不在目录中：$path');
    if (_processedStories.contains(path)) throw FormatException('重复扫描剧情：$path');
    final script = StoryScript.parse(utf8.decode(bytes));
    metadata['scriptHash'] = sha256.convert(bytes).toString();
    final perPerson = <String, List<Map<String, dynamic>>>{};
    // 跟踪舞台立绘状态（语义对齐播放器的 character/charslot 处理），
    // 为未归属说话人积累“说话时台上是谁”的共现证据。
    final stageNames = <String, String>{};
    for (var index = 0; index < script.commands.length; index++) {
      final command = script.commands[index];
      if (command.tag == 'character') {
        final first = command.value('name');
        final second = command.value('name2');
        if (first.isEmpty && second.isEmpty) {
          stageNames.clear();
        } else {
          if (first.isNotEmpty) _touchAvgKey(first, path);
          if (second.isNotEmpty) _touchAvgKey(second, path);
          if (second.isEmpty) {
            stageNames
              ..removeWhere((slot, _) => slot != 'm')
              ..remove('r');
            if (first.isNotEmpty) stageNames['m'] = first;
          } else {
            stageNames
              ..remove('m')
              ..removeWhere((slot, _) => slot == 'l' || slot == 'r');
            if (first.isNotEmpty) stageNames['l'] = first;
            if (second.isNotEmpty) stageNames['r'] = second;
          }
        }
      } else if (command.tag == 'charslot') {
        final rawSlot = command.value('slot').trim().toLowerCase();
        final name = command.value('name');
        if (rawSlot.isEmpty) {
          stageNames.clear();
        } else if (name == 'char_empty') {
          stageNames.remove(rawSlot);
        } else if (name.isNotEmpty) {
          _touchAvgKey(name, path);
          stageNames[rawSlot] = name;
        }
      }
      if (command.tag != 'dialogue' || command.text.trim().isEmpty) continue;
      final name = normalizedName(command.value('name'));
      if (name.isEmpty) continue;
      namedLines++;
      speakerLines.update(name, (value) => value + 1, ifAbsent: () => 1);
      for (final key in stageNames.values) {
        // char_empty 是清台占位，未入 avgKeyUsage，也不构成共现证据。
        if (key == 'char_empty') continue;
        final usage = avgKeyUsage[key]!;
        (usage['speakers'] as Map<String, int>).update(
          name,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
      }
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
            'stories': <String>{},
            'avgKeys': <String, int>{},
          },
        );
        item['lineCount'] = (item['lineCount'] as int) + 1;
        (item['stories'] as Set<String>).add(path);
        for (final key in stageNames.values) {
          (item['avgKeys'] as Map<String, int>).update(
            key,
            (value) => value + 1,
            ifAbsent: () => 1,
          );
        }
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

  /// 报告与 CSV 只能拿到可序列化的副本：Set/内部结构不得直接进 JSON。
  List<Map<String, dynamic>> get unmatchedSpeakers =>
      [
        for (final item in unmatched.values)
          {
            ...{
              'name': item['name'],
              'lineCount': item['lineCount'],
              'sampleStory': item['sampleStory'],
              'sampleText': item['sampleText'],
              'avgKeys': item['avgKeys'],
            },
            'stories':
                (item['stories'] as Set<String>? ?? const <String>{}).toList()
                  ..sort(),
          },
      ]..sort((a, b) {
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
    // 门禁按标准形态统计取图；一人靠异格/剧情立绘兑底会在报告中单独点名。
    final operators = people.values
        .where((person) => person.kind == 'operator')
        .toList();
    var baseCovered = 0;
    var fallbackPortraits = 0;
    for (final person in operators) {
      final baseId = person.forms.firstOrNull?['id'];
      final hasBase =
          baseId != null &&
          person.artCandidates.any(
            (art) =>
                art['formId'] == baseId &&
                art['kind'] == 'elite0' &&
                art['verified'] == true,
          );
      if (hasBase) {
        baseCovered++;
      } else if (person.portrait != null) {
        fallbackPortraits++;
      }
    }
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
      'baseFormPortraitCoverage': operators.isEmpty
          ? 0
          : baseCovered / operators.length,
      'operatorsWithFallbackPortrait': fallbackPortraits,
      'artVerification': 'not_run',
    };
  }
}

String csvCell(Object? value) {
  var text = value?.toString() ?? '';
  if (RegExp(r'^[=+@\-\t\r]').hasMatch(text)) text = "'$text";
  return '"${text.replaceAll('"', '""')}"';
}

/// 首行 BOM：这两份表用于 Excel 人工查询，避免中文乱码。
String peopleLookupCsv(CharacterCatalog catalog) {
  final included = catalog.includedPeople.map((p) => p['id']).toSet();
  final rows = [
    [
      'name',
      'id',
      'kind',
      'faction',
      'aliases',
      'lineCount',
      'storyCount',
      'formCount',
      'inIndex',
      'detailFile',
    ],
    for (final person
        in catalog.people.values.toList()..sort((a, b) => a.id.compareTo(b.id)))
      [
        person.name,
        person.id,
        person.kind,
        person.faction,
        person.aliases.join(';'),
        person.lineCount,
        person.appearances.length,
        person.forms.length,
        included.contains(person.id) ? 'yes' : 'no',
        person.id.startsWith('op:') ? detailFilename(person.id) : '',
      ],
  ];
  return '\uFEFF${rows.map((r) => r.map(csvCell).join(',')).join('\r\n')}\r\n';
}

String avgKeysCsv(CharacterCatalog catalog) {
  // 从已存在人物的立绘候选反解 key 绑定；复杂资源名按解码后的文件主体。
  final binding = <String, List<String>>{};
  for (final person in catalog.people.values) {
    for (final art in person.artCandidates) {
      if (art['kind'] != 'avg') continue;
      final filename = Uri.parse(art['url'] as String).pathSegments.last;
      final match = RegExp(r'^Avg_(.+)\.png$').firstMatch(filename);
      if (match != null) {
        binding.putIfAbsent(match.group(1)!, () => []).add(person.name);
      }
    }
  }
  // key 口径 = 剧本中登场过的 key ∪ 已绑定在人物卡上的 key；
  // 后者可能从未在台词处直接登台（如一览页立绘），查询表必须完整。
  final keys = {...catalog.avgKeyUsage.keys, ...binding.keys}.toList()..sort();
  String topSpeakers(Map<String, dynamic> usage) {
    final speakers = (usage['speakers'] as Map<String, int>).entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return speakers.take(3).map((e) => '${e.key}x${e.value}').join(';');
  }

  final rows = [
    ['key', 'useStories', 'coSpeakers', 'topCoSpeakers', 'boundTo'],
    for (final key in keys)
      [
        key,
        (catalog.avgKeyUsage[key]?['stories'] as Set?)?.length ?? 0,
        (catalog.avgKeyUsage[key]?['speakers'] as Map?)?.length ?? 0,
        catalog.avgKeyUsage[key] == null
            ? ''
            : topSpeakers(catalog.avgKeyUsage[key]!),
        binding[key]?.join(';') ?? '',
      ],
  ];
  return '\uFEFF${rows.map((r) => r.map(csvCell).join(',')).join('\r\n')}\r\n';
}

String unmatchedCsv(List<Map<String, dynamic>> rows) => [
  'name,lineCount,stories,sampleStory,sampleText,avgKeys,candidate,confidence',
  for (final row in rows)
    [
      row['name'],
      row['lineCount'],
      (row['stories'] as List? ?? const []).length,
      row['sampleStory'],
      row['sampleText'],
      ((row['avgKeys'] as Map? ?? const {}).entries.toList()..sort((a, b) {
            final count = (b.value as int).compareTo(a.value as int);
            return count != 0
                ? count
                : (a.key as String).compareTo(b.key as String);
          }))
          .take(3)
          .map((entry) => '${entry.key}x${entry.value}')
          .join(';'),
      '',
      '',
    ].map(csvCell).join(','),
  '',
].join('\r\n');
