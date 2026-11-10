import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arknights_story_player/story_player/script.dart';

import '../tool/character_index/catalog.dart';

Map<String, dynamic> unit(
  String name, {
  String english = '',
  String profession = 'CASTER',
  bool obtainable = true,
}) => {
  'name': name,
  'appellation': english,
  'profession': profession,
  'rarity': 'TIER_5',
  'isNotObtainable': !obtainable,
};

CharacterCatalog catalog({List<dynamic> merges = const []}) {
  return CharacterCatalog()..loadOperators(
    characters: {
      'char_001_base': unit('甲', english: 'Alpha'),
      'char_002_alt': unit('异格甲', english: 'Alpha the Second'),
      'char_003_other': unit('乙', english: 'Beta'),
      'char_004_summon': unit('召唤物', profession: 'TOKEN'),
      'char_005_hidden': unit('未实装', obtainable: false),
    },
    patches: {
      'patchChars': {'char_006_patch': unit('甲', profession: 'WARRIOR')},
      'infos': {
        'char_001_base': {
          'tmplIds': ['char_001_base', 'char_006_patch'],
        },
      },
    },
    handbook: {
      'handbookDict': {
        'char_001_base': {
          'storyTextAudio': [
            {
              'storyTitle': '档案',
              'stories': [
                {'storyText': '基础资料', 'unLockType': 'DIRECT'},
                {
                  'storyText': '深层经历',
                  'unLockType': 'TRUST',
                  'patchIdList': ['char_006_patch'],
                },
              ],
            },
          ],
        },
      },
    },
    merges: merges,
  );
}

void addStories(CharacterCatalog catalog, List<String> paths) {
  catalog.loadStories({
    'group': {
      'entryType': 'ACTIVITY',
      'name': '测试活动',
      'infoUnlockDatas': [
        for (final path in paths)
          {'storyTxt': path, 'storyName': path, 'storyCanShow': false},
      ],
    },
  });
}

String npcTable(List<String> rows) =>
    '<table><tr><th>名称/代号</th><th>简介</th><th>出处</th><th>立绘</th></tr>'
    '${rows.join()}</table>';
String npcRow(String name, {String image = ''}) =>
    '<tr><td>$name</td><td>包含结局的简介</td><td>测试活动</td><td>$image</td></tr>';

void main() {
  test('官方 patch 合并为同一人物，英文候选不自动归并', () {
    final value = catalog();
    expect(value.people.length, 3);
    expect(value.people['op:char_001_base']!.forms.map((f) => f['id']), [
      'char_001_base',
      'char_006_patch',
    ]);
    expect(value.people.containsKey('op:char_002_alt'), isTrue);
    expect(value.mergeCandidates.single['alt'], 'char_002_alt');
    expect(value.patchFormCount, 1);
  });

  test('人工异格归并同时合并称呼和出场', () {
    final value = catalog(
      merges: [
        {'base': 'char_001_base', 'alt': 'char_002_alt'},
      ],
    );
    addStories(value, ['activities/demo/one']);
    value.scanStory(
      'activities/demo/one',
      utf8.encode('''[name=甲]第一句
[name=异格甲]第二句
[name=甲（近卫）]第三句'''),
    );
    final person = value.people['op:char_001_base']!;
    expect(value.people.length, 2);
    expect(person.forms.length, 3);
    expect(person.appearances.length, 1);
    expect(person.lineCount, 3);
  });

  test('拒绝缺失、重叠、成链和成环的人工映射', () {
    for (final merges in [
      [
        {'base': 'char_001_base', 'alt': 'char_missing'},
      ],
      [
        {'base': 'char_001_base', 'alt': 'char_006_patch'},
      ],
      [
        {'base': 'char_001_base', 'alt': 'char_002_alt'},
        {'base': 'char_002_alt', 'alt': 'char_003_other'},
      ],
      [
        {'base': 'char_001_base', 'alt': 'char_002_alt'},
        {'base': 'char_002_alt', 'alt': 'char_001_base'},
      ],
    ]) {
      expect(() => catalog(merges: merges), throwsFormatException);
    }
  });

  test('别名不得指向缺失人物、多个身份或排除称呼', () {
    final value = catalog()..blocklist.add('？？？');
    value.loadAliases({'真实姓名': 'op:char_001_base'});
    expect(
      () => value.loadAliases({'真实姓名': 'op:char_003_other'}),
      throwsFormatException,
    );
    expect(
      () => value.loadAliases({'未知': 'op:char_missing'}),
      throwsFormatException,
    );
    expect(
      () => value.loadAliases({'？？？': 'op:char_001_base'}),
      throwsFormatException,
    );
  });

  test('深层档案保留剧透标记与适用形态', () {
    final sections = catalog().people['op:char_001_base']!.profile;
    expect(sections.first['spoiler'], isFalse);
    expect(sections.last['spoiler'], isTrue);
    expect(sections.last['formIds'], ['char_006_patch']);
  });

  test('NPC 只解析顶层四列表，排除占位称呼与干员重复项', () {
    final value = catalog()..blocklist.add('商队头领');
    final image =
        '<table>${npcRow('嵌套角色')}</table>'
        '<img src=https://media.prts.wiki/thumb/a/ab/Avg_demo.png/120px-Avg_demo.png>'
        '<img src=https://example.com/Avg_wrong.png>';
    value.loadNpcs(
      npcTable([
        npcRow('医生（代号）*', image: image),
        npcRow('？？？'),
        npcRow('甲的父亲'),
        npcRow('商队头领'),
        npcRow('甲'),
      ]),
    );
    final npc = value.people.values.singleWhere((p) => p.kind == 'npc');
    expect(npc.name, '医生(代号)*');
    expect(npc.profile.single['spoiler'], isTrue);
    expect(
      npc.artCandidates.single['url'],
      mediaUri('Avg_demo.png').toString(),
    );
    expect(npc.artCandidates.single['verified'], isFalse);
    expect(detailFilename(npc.id), isNot(contains('*')));
    expect(value.excludedNpcs.length, 3);
    expect(value.npcOperatorOverlaps, ['甲']);
  });

  test('NPC 页面结构变化必须显式失败', () {
    expect(() => catalog().loadNpcs('<p>维护中</p>'), throwsFormatException);
  });

  test('目录保持原顺序，不按 storyCanShow 过滤，并去重', () {
    final value = catalog();
    addStories(value, ['activities/z', 'activities/a', 'activities/z']);
    expect(value.stories.keys, ['activities/z', 'activities/a']);
    expect(value.duplicateStoryEntries, 1);
    for (final path in ['../private', '/absolute', 'a//b', 'a.txt']) {
      expect(() => addStories(catalog(), [path]), throwsFormatException);
    }
  });

  test('节选使用播放器 commandIndex，保留原字节 hash 与真实行号', () {
    final source = [
      '// 注释',
      '',
      '[Background(image=bg)]',
      '[name=甲]这是最长的一句台词，用来验证首句不会占用中间节选名额。${String.fromCharCode(92)}',
      '续行内容',
      '[name=真实姓名]中间句',
      '[name=甲]末句',
      '[name=？？？]未知身份',
      '[name=陌生人]未匹配',
      '[name=Alpha]英文不推断身份',
      '[name=]旁白',
    ].join(String.fromCharCodes([13, 10]));
    final bytes = utf8.encode(source);
    final value = catalog()..blocklist.add('？？？');
    value.loadAliases({'真实姓名': 'op:char_001_base'});
    addStories(value, ['activities/demo']);
    value.scanStory('activities/demo', bytes);
    final script = StoryScript.parse(source);
    final appearance = value.people['op:char_001_base']!.appearances.single;
    final snippets = appearance['snippets'] as List;
    expect(appearance['lineCount'], 3);
    expect(snippets.length, 3);
    expect(snippets.first['line'], 4);
    expect(snippets.first['text'], contains('续行内容'));
    for (final snippet in snippets) {
      final command = script.commands[snippet['commandIndex'] as int];
      expect(command.text, snippet['text']);
      expect(command.line, snippet['line']);
    }
    expect(
      value.stories['activities/demo']!['scriptHash'],
      sha256.convert(bytes).toString(),
    );
    expect(value.namedLines, 6);
    expect(value.matchedLines, 3);
    expect(value.blockedLines, 1);
    expect(value.unmatched.keys, ['陌生人', 'Alpha']);
    expect(value.statistics()['namedLineCoverage'], 0.5);
    expect(value.statistics()['top200NamedLineCoverage'], 0.5);
    expect(
      () => value.scanStory('activities/demo', bytes),
      throwsFormatException,
    );
  });

  test('一两句的出场不生成重复节选，出场按目录排序', () {
    final value = catalog();
    addStories(value, ['first', 'second']);
    value.scanStory('second', utf8.encode('[name=甲]后篇'));
    value.scanStory(
      'first',
      utf8.encode('''[name=甲]首句
[name=甲]末句'''),
    );
    value.sortAppearances();
    final appearances = value.people['op:char_001_base']!.appearances;
    expect(appearances.map((a) => a['story']), ['first', 'second']);
    expect((appearances.first['snippets'] as List).length, 2);
    expect((appearances.last['snippets'] as List).length, 1);
  });

  test('中间节选长度相同取靠后一句，再按剧情顺序展示', () {
    final value = catalog();
    addStories(value, ['demo']);
    value.scanStory(
      'demo',
      utf8.encode('''[name=甲]首句
[name=甲]中间甲
[name=甲]中间乙
[name=甲]末句'''),
    );
    final snippets =
        value.people['op:char_001_base']!.appearances.single['snippets']
            as List;
    expect(snippets.map((s) => s['text']), ['首句', '中间乙', '末句']);
  });

  test('有档案但零出场的人物保留，导航索引不含剧透正文', () {
    final value = catalog();
    final entry = value.includedPeople.single;
    expect(entry['id'], 'op:char_001_base');
    expect(jsonEncode(entry), isNot(contains('深层经历')));
    expect(jsonEncode(entry), isNot(contains('基础资料')));
    expect(value.statistics()['namedLineCoverage'], isNull);
    expect(value.statistics()['artVerification'], 'not_run');
  });
}
