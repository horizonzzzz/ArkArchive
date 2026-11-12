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

  test('卡片头像跟随标准形态，不因立绘候选插入顺序漂移', () {
    // character_table 的键序不保证标准形态在前，异格键序在前是常态。
    final value = CharacterCatalog()
      ..loadOperators(
        characters: {
          'char_902_altfirst': unit('异格甲', english: 'Alpha the Second'),
          'char_901_base': unit('甲', english: 'Alpha'),
        },
        patches: {
          'patchChars': <String, dynamic>{},
          'infos': <String, dynamic>{},
        },
        handbook: {'handbookDict': <String, dynamic>{}},
        merges: [
          {'base': 'char_901_base', 'alt': 'char_902_altfirst'},
        ],
      );
    final person = value.people['op:char_901_base']!;
    expect(person.forms.first['id'], 'char_901_base');
    for (final art in person.artCandidates) {
      art['verified'] = true;
    }
    expect(person.portrait?['formId'], 'char_901_base');
    expect(person.portrait?['kind'], 'elite0');
    expect(
      Uri.decodeFull(person.toIndex()['portraitUrl'] as String),
      contains('立绘_甲_1'),
    );
    // 画廊候选同样对齐 forms 顺序，避免详情页立绘序列漂移。
    expect(
      person.artCandidates.take(3).map((a) => a['formId']),
      everyElement('char_901_base'),
    );
  });

  test('标准形态立绘缺失时退回其它形态，有图仍好过占位', () {
    final value = CharacterCatalog()
      ..loadOperators(
        characters: {
          'char_902_altfirst': unit('异格甲'),
          'char_901_base': unit('甲'),
        },
        patches: {
          'patchChars': <String, dynamic>{},
          'infos': <String, dynamic>{},
        },
        handbook: {'handbookDict': <String, dynamic>{}},
        merges: [
          {'base': 'char_901_base', 'alt': 'char_902_altfirst'},
        ],
      );
    final person = value.people['op:char_901_base']!;
    for (final art in person.artCandidates) {
      art['verified'] =
          art['formId'] != 'char_901_base' || art['kind'] != 'elite0';
    }
    expect(person.portrait?['formId'], 'char_902_altfirst');
    final statistics = value.statistics();
    expect(statistics['baseFormPortraitCoverage'], 0);
    expect(statistics['operatorsWithFallbackPortrait'], 1);
  });

  test('基准形态立绘覆盖率按干员标准形态统计', () {
    final value = catalog(
      merges: [
        {'base': 'char_001_base', 'alt': 'char_002_alt'},
      ],
    );
    for (final person in value.people.values) {
      for (final art in person.artCandidates) {
        art['verified'] = art['formId'] != 'char_002_alt';
      }
    }
    // char_003_other 标准形态有图，甲的标准形态也有图，覆盖率应为 1。
    expect(value.statistics()['baseFormPortraitCoverage'], 1);
    expect(value.statistics()['operatorsWithFallbackPortrait'], 0);
  });

  test('npc_extra：边缘人物建卡、伪装归并公开称呼', () {
    final value = catalog()..loadNpcs(npcTable([npcRow('已知人物')]));
    value.loadAliases({'真实姓名': 'op:char_001_base'});
    value.loadNpcExtras({
      '边缘人物': {
        'faction': '维多利亚',
        'avg': 'avg_npc_777_1',
        'aliases': ['“军官”'],
      },
      '“甲”': {'mergeInto': 'op:char_001_base'},
      '已知人物': {'avg': 'avg_npc_888_1'},
    });
    final person = value.people['npc:%E8%BE%B9%E7%BC%98%E4%BA%BA%E7%89%A9']!;
    expect(person.kind, 'npc');
    expect(person.faction, '维多利亚');
    expect(person.aliases, contains('“军官”'));
    // 皮肤索引枚举 _1.._4，交给图片校验淘汰，构建期不做网络请求。
    expect(
      person.artCandidates.map((a) => Uri.decodeFull(a['url'] as String)),
      everyElement(contains('Avg_avg_npc_777_')),
    );
    expect(person.artCandidates.length, 4);
    expect(person.artCandidates.first.containsKey('spoiler'), isFalse);
    // 已有卡片只补充候选，不重建。
    final known = value.people['npc:%E5%B7%B2%E7%9F%A5%E4%BA%BA%E7%89%A9']!;
    expect(
      known.artCandidates.any(
        (a) => (a['url'] as String).contains('Avg_avg_npc_888'),
      ),
      isTrue,
    );
    // 归并称呼同时用于台词归属和搜索。
    final op = value.people['op:char_001_base']!;
    addStories(value, ['activities/demo/one']);
    value.scanStory('activities/demo/one', utf8.encode('[name=“甲”]一句伪装台词'));
    expect(op.lineCount, 1);
    expect(op.aliases, contains('“甲”'));
    expect(op.toIndex()['searchText'] as String, contains('“甲”'));
  });

  test('npc_extra：拒绝伪装目标缺失、阻塞名单与称呼冲突', () {
    final value = catalog()..blocklist.add('？？？');
    expect(
      () => value.loadNpcExtras({
        '甲': {'mergeInto': 'op:char_missing'},
      }),
      throwsFormatException,
    );
    expect(
      () => value.loadNpcExtras({
        '？？？': {'mergeInto': 'op:char_001_base'},
      }),
      throwsFormatException,
    );
    expect(
      () => value.loadNpcExtras({
        '乙': {'mergeInto': '甲卡'},
      }),
      throwsFormatException,
    );
    value.loadAliases({'冲突名': 'op:char_003_other'});
    expect(
      () => value.loadNpcExtras({
        '冲突名': {'mergeInto': 'op:char_001_base'},
      }),
      throwsFormatException,
    );
  });

  test('未归属说话人记录立绘共现证据与篇目数', () {
    final value = catalog();
    addStories(value, ['activities/demo/one', 'activities/demo/two']);
    value.scanStory(
      'activities/demo/one',
      utf8.encode(
        '[Character(name="char_a_1",name2="char_b_1")]\n[name=边缘人物]你好',
      ),
    );
    value.scanStory(
      'activities/demo/two',
      utf8.encode('[Character(name="char_a_1")]\n[name=边缘人物]又见面了'),
    );
    final item = value.unmatched['边缘人物']!;
    expect(item['lineCount'], 2);
    expect((item['stories'] as Set).length, 2);
    expect(item['avgKeys'], {'char_a_1': 2, 'char_b_1': 1});
    final row = unmatchedCsv(value.unmatchedSpeakers);
    expect(row, contains('char_a_1x2'));
    // 报告直接 jsonEncode，Set 等内部结构必须在输出层转换。
    expect(
      jsonEncode(value.unmatchedSpeakers),
      contains('activities/demo/one'),
    );
  });

  test('npc_extra：群体称呼模式拒绝建卡，伪装归并不受影响', () {
    final value = catalog();
    const patterns = {r'(干员|成员|战士)$', '^萨卡兹'};
    expect(
      () => value.loadNpcExtras({'罗德岛干员': {}}, groupPatterns: patterns),
      throwsFormatException,
    );
    expect(
      () => value.loadNpcExtras({
        '萨卡兹战士': {'avg': 'avg_npc_001_1'},
      }, groupPatterns: patterns),
      throwsFormatException,
    );
    // 伪装归并非建卡，允许群体化称呼归入真身。
    value.loadNpcExtras({
      '“医疗干员”': {'mergeInto': 'op:char_001_base'},
    }, groupPatterns: patterns);
    expect(value.people['op:char_001_base']!.aliases, contains('“医疗干员”'));
  });

  test('avg 资源使用统计覆盖全部舞台登场与说话人共现', () {
    final value = catalog()..loadNpcs(npcTable([npcRow('已知人物')]));
    addStories(value, ['activities/demo/one', 'activities/demo/two']);
    value.scanStory(
      'activities/demo/one',
      utf8.encode(
        '[Character(name="avg_npc_111#1",name2="char_001_base")]\n'
        '[name=甲]第一句\n[name=边缘人物]第二句',
      ),
    );
    value.scanStory(
      'activities/demo/two',
      utf8.encode(
        '[Character(name="avg_npc_111#1")]\n[name=边缘人物]第三句\n'
        '[Character(name="char_empty")]\n[name=乙]清台后说话',
      ),
    );
    final key = value.avgKeyUsage['avg_npc_111#1']!;
    expect((key['stories'] as Set).length, 2);
    expect(key['speakers'], {'甲': 1, '边缘人物': 2});
    // 干员形态 key 同样入表；char_empty 清台占位不构成资源。
    expect(value.avgKeyUsage.containsKey('char_001_base'), isTrue);
    expect(value.avgKeyUsage.containsKey('char_empty'), isFalse);
  });

  test('人物与 avg 资源对照表可直接用于人工查询', () {
    final value = catalog()
      ..loadNpcs(
        npcTable([
          npcRow(
            '已知人物',
            image:
                '<img src="https://media.prts.wiki/thumb/1/11/'
                'Avg_avg_npc_099_1.png/240px-Avg_avg_npc_099_1.png">',
          ),
        ]),
      )
      ..loadAliases({'真实姓名': 'op:char_001_base'})
      ..loadNpcExtras({
        '边缘人物': {'avg': 'avg_npc_777_1'},
      });
    addStories(value, ['activities/demo/one']);
    value.scanStory(
      'activities/demo/one',
      utf8.encode('[Character(name="avg_npc_777_1")]\n[name=边缘人物]你好'),
    );
    final people = peopleLookupCsv(value);
    // 人工对照表用名字可查到 mergeInto 需要的完整 ID，Excel 友好带 BOM。
    expect(people, startsWith('\uFEFF'));
    expect(people, contains('"甲","op:char_001_base","operator"'));
    expect(
      people,
      contains('"已知人物","npc:%E5%B7%B2%E7%9F%A5%E4%BA%BA%E7%89%A9","npc"'),
    );
    expect(
      people,
      contains('"边缘人物","npc:%E8%BE%B9%E7%BC%98%E4%BA%BA%E7%89%A9","npc"'),
    );
    // avg 对照表给出绑定状态：777 已绑定边缘人物，099 绑定一览页人物，复用度可见。
    final avg = avgKeysCsv(value);
    expect(avg, startsWith('\uFEFF'));
    expect(avg, contains('avg_npc_777_1'));
    expect(avg, contains('边缘人物'));
    expect(avg, contains('avg_npc_099_1'));
    expect(avg, contains('已知人物'));
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

  test('档案保留适用形态，不生成剧透标记', () {
    final sections = catalog().people['op:char_001_base']!.profile;
    expect(
      sections.every((section) => !section.containsKey('spoiler')),
      isTrue,
    );
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
    expect(npc.profile.single.containsKey('spoiler'), isFalse);
    expect(npc.artCandidates.single.containsKey('spoiler'), isFalse);
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

  test('有档案但零出场的人物保留，导航索引不含档案正文', () {
    final value = catalog();
    final entry = value.includedPeople.single;
    expect(entry['id'], 'op:char_001_base');
    expect(jsonEncode(entry), isNot(contains('深层经历')));
    expect(jsonEncode(entry), isNot(contains('基础资料')));
    expect(value.statistics()['namedLineCoverage'], isNull);
    expect(value.statistics()['artVerification'], 'not_run');
  });
}
