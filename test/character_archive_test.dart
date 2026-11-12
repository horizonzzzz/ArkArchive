import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/app/app_theme.dart';
import 'package:arknights_story_player/app/character_archive_data.dart';
import 'package:arknights_story_player/app/character_archive_paths.dart';
import 'package:arknights_story_player/app/character_archive_page.dart';
import 'package:arknights_story_player/app/character_detail_page.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';

import 'data_test.dart' show MemoryCache;

Map<String, dynamic> personJson({
  String id = 'op:char_002_amiya',
  String name = '阿米娅',
  String kind = 'operator',
  int count = 2,
}) => {
  'id': id,
  'name': name,
  'kind': kind,
  'appellation': 'Amiya',
  'aliases': ['奇美拉（测试）'],
  'class': '术师',
  'rarity': 5,
  'faction': '罗德岛',
  'forms': kind == 'operator'
      ? [
          {'id': 'char_002_amiya', 'label': '阿米娅', 'class': '术师', 'rarity': 5},
          {
            'id': 'char_1037_amiya3',
            'label': '阿米娅（医疗）',
            'class': '医疗',
            'rarity': 6,
          },
        ]
      : [],
  'storyCount': count,
  'lineCount': count * 10,
  'firstStory': count > 0 ? 'main/one' : null,
  'detailFile': characterDetailFilename(id),
};

Map<String, dynamic> indexJson() => {
  'schema': 1,
  'version': 'fixture',
  'generatedAt': '2026-11-10T00:00:00Z',
  'coverage': {'complete': true},
  'people': [
    personJson(),
    personJson(id: 'npc:friend', name: '阿米娅的朋友', kind: 'npc', count: 0),
  ],
  'stories': {
    'main/one': {
      'chapter': '测试篇章',
      'code': '0-1',
      'name': '初见',
      'tag': '行动前',
      'order': 0,
      'scriptHash': 'hash',
    },
  },
};

Map<String, dynamic> detailJson() => {
  'id': 'op:char_002_amiya',
  'profile': [
    {
      'formId': 'char_002_amiya',
      'title': '基础档案',
      'text': '公开资料',
      'spoiler': false,
    },
    {
      'formId': 'char_002_amiya',
      'title': '深层档案',
      'text': '隐藏身份',
      'spoiler': true,
    },
    {
      'formId': 'char_002_amiya',
      'formIds': ['char_1037_amiya3'],
      'title': '医疗档案',
      'text': '医疗形态资料',
      'spoiler': false,
    },
  ],
  'artCandidates': [],
  'appearances': [
    {
      'story': 'main/one',
      'lineCount': 20,
      'snippets': [
        {'commandIndex': 3, 'line': 5, 'speaker': '阿米娅', 'text': '剧情秘密对白'},
      ],
    },
  ],
};

class ArchiveBundle extends CachingAssetBundle {
  final reads = <String, int>{};
  bool fail = false;
  Map<String, dynamic> detail = detailJson();
  Map<String, dynamic> index = indexJson();
  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    reads.update(key, (v) => v + 1, ifAbsent: () => 1);
    if (fail) throw FlutterError('模拟资源缺失');
    return jsonEncode(key.endsWith('index.json') ? index : detail);
  }

  @override
  Future<ByteData> load(String key) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('搜索代号和别名，并将精确名称放在包含匹配前', () {
    final index = CharacterIndex.fromJson(indexJson());
    expect(index.search(query: ' 阿米娅 ').first.name, '阿米娅');
    expect(index.search(query: 'aMIya').first.name, '阿米娅');
    expect(index.search(query: '奇美拉(测试)').first.name, '阿米娅');
    expect(index.search(query: '不存在'), isEmpty);
    expect(index.search(kind: 'npc').single.name, '阿米娅的朋友');
  });

  test('筛选覆盖异格形态，但职业和星级必须属于同一形态', () {
    final index = CharacterIndex.fromJson(indexJson());
    expect(index.search(profession: '医疗', rarity: 6).single.name, '阿米娅');
    expect(index.search(profession: '术师', rarity: 6), isEmpty);
    expect(index.search(profession: '医疗', faction: '其他阵营'), isEmpty);
  });

  test('首次出场排序将没有识别记录的人物放到最后', () {
    final index = CharacterIndex.fromJson(indexJson());
    expect(
      index.search(order: CharacterOrder.firstAppearance).last.storyCount,
      0,
    );
  });

  test('长 NPC 名称使用定长安全文件名且保持唯一', () {
    final id = 'npc:${Uri.encodeComponent(List.filled(40, '叶莉萨维塔').join())}';
    final filename = characterDetailFilename(id);
    expect(filename.length, 73);
    expect(Uri.encodeComponent(filename), filename);
    expect(characterDetailFilename('$id-a'), isNot(filename));
  });

  test('拒绝不完整索引和逃逸详情路径', () {
    expect(
      () => CharacterIndex.fromJson({
        ...indexJson(),
        'coverage': {'complete': false},
      }),
      throwsFormatException,
    );
    expect(
      () => CharacterSummary.fromJson({
        ...personJson(),
        'detailFile': '../index.json',
      }),
      throwsFormatException,
    );
  });

  test('档案适配官方 patch 的形态范围', () {
    final detail = CharacterDetail.fromJson(detailJson());
    expect(detail.profile.last.appliesTo('char_1037_amiya3'), isTrue);
    expect(detail.profile.last.appliesTo('char_002_amiya'), isFalse);
  });

  test('仓库复用读取且可在失败后显式重试', () async {
    final bundle = ArchiveBundle();
    final repository = CharacterRepository(bundle: bundle);
    final index = await repository.loadIndex();
    await repository.loadIndex();
    expect(bundle.reads['assets/characters/index.json'], 1);
    bundle.fail = true;
    await expectLater(
      repository.loadDetail(index.people.first),
      throwsFlutterError,
    );
    bundle.fail = false;
    final detail = await repository.loadDetail(
      index.people.first,
      reload: true,
    );
    expect(detail.id, index.people.first.id);
    await repository.loadDetail(index.people.first);
    expect(bundle.reads['assets/characters/details/op_char_002_amiya.json'], 2);
  });

  test('仓库拒绝详情人物错配', () async {
    final bundle = ArchiveBundle()..detail = {'id': 'npc:wrong'};
    final repository = CharacterRepository(bundle: bundle);
    final index = await repository.loadIndex();
    await expectLater(
      repository.loadDetail(index.people.first),
      throwsFormatException,
    );
  });

  test('真实随包资源可以离线读取索引和阿米娅三形态', () async {
    final repository = CharacterRepository();
    final index = await repository.loadIndex();
    // 快照人数随数据批次变化；下限防止意外打包成空数据或样本数据。
    expect(index.people.length, greaterThan(1000));
    final person = index.people.singleWhere((p) => p.id == 'op:char_002_amiya');
    expect(person.forms.length, 3);
    expect(person.forms.map((f) => f.name), ['阿米娅', '阿米娅(近卫)', '阿米娅(医疗)']);
    expect(index.search(query: '阿米娅(近卫)').single.id, person.id);
    expect(index.search(query: '恩希欧迪斯').single.name, '银灰');
    expect(index.search(query: '维什戴尔').single.name, 'W');
    expect(index.search(query: '米拉娜').single.kind, 'npc');
    expect((await repository.loadDetail(person)).profile, isNotEmpty);
  });

  Future<void> pumpArchive(
    WidgetTester tester, {
    double width = 375,
    double height = 900,
    double scale = 1,
    ArchiveBundle? bundle,
    bool detail = false,
    CharacterReplay? replay,
  }) async {
    tester.view.reset();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.reset);
    final store = AssetStore(cache: MemoryCache());
    addTearDown(store.close);
    final repository = CharacterRepository(bundle: bundle ?? ArchiveBundle());
    final index = CharacterIndex.fromJson(indexJson());
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: detail
            ? CharacterDetailPage(
                person: index.people.first,
                index: index,
                repository: repository,
                store: store,
                onReplay: replay,
              )
            : Scaffold(
                body: CharacterArchivePage(
                  store: store,
                  repository: repository,
                ),
              ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('窄屏搜索、打开人物、返回后保留搜索条件', (tester) async {
    await pumpArchive(tester);
    await tester.enterText(find.byType(TextField), '阿米娅');
    await tester.pumpAndSettle();
    await tester.tap(find.text('阿米娅').last);
    await tester.pumpAndSettle();
    expect(find.text('基础档案'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '阿米娅',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('空结果分别清除搜索和筛选，筛选面板可提交', (tester) async {
    await pumpArchive(tester);
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('医疗'));
    await tester.ensureVisible(find.text('应用筛选'));
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('筛选：已选 1 项'), findsOneWidget);
    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '不存在',
    );
    await tester.tap(find.widgetWithText(TextButton, '清除搜索'));
    await tester.pumpAndSettle();
    expect(find.text('阿米娅'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('筛选组合、取消切换及确认切换保留正确状态', (tester) async {
    await pumpArchive(tester);
    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('医疗'));
    await tester.ensureVisible(find.text('6 星'));
    await tester.tap(find.text('6 星'));
    await tester.ensureVisible(find.text('应用筛选'));
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('筛选：已选 2 项'), findsOneWidget);
    expect(find.text('阿米娅'), findsOneWidget);
    expect(find.text('阿米娅的朋友'), findsNothing);
    await tester.ensureVisible(find.text('剧情角色').first);
    await tester.tap(find.text('剧情角色').first);
    await tester.pumpAndSettle();
    expect(find.text('切换后将清除职业、阵营和星级筛选条件。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('筛选：已选 2 项'), findsOneWidget);
    await tester.tap(find.text('剧情角色').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('筛选'), findsOneWidget);
    expect(find.text('阿米娅的朋友'), findsOneWidget);
  });

  testWidgets('窄屏放大文字时页头和筛选仍可操作', (tester) async {
    await pumpArchive(tester, width: 320, height: 700, scale: 1.5);
    expect(find.byKey(const Key('character-header')), findsOneWidget);
    expect(find.byTooltip('筛选'), findsOneWidget);
    expect(find.byTooltip('排序：出场次数'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('医疗'));
    await tester.tap(find.text('医疗'));
    await tester.ensureVisible(find.text('应用筛选'));
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('筛选：已选 1 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('筛选重置仅修改草稿，关闭后保留已应用条件', (tester) async {
    await pumpArchive(tester);
    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('医疗'));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('罗德岛').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('应用筛选'));
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('筛选：已选 2 项'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选：已选 2 项'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('重置筛选'));
    await tester.tap(find.text('重置筛选'));
    await tester.pumpAndSettle();
    expect(find.text('全部阵营'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byTooltip('筛选：已选 2 项'), findsOneWidget);
  });

  testWidgets('人物列表滚动时页头固定', (tester) async {
    final bundle = ArchiveBundle();
    bundle.index = {
      ...indexJson(),
      'people': [
        for (var i = 0; i < 30; i++) personJson(id: 'op:char_$i', name: '人物$i'),
      ],
    };
    await pumpArchive(tester, bundle: bundle);
    final header = find.byKey(const Key('character-header'));
    final before = tester.getTopLeft(header);
    final list = find.byKey(const PageStorageKey('character-archive-list'));
    await tester.drag(list, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header), before);
    expect(find.text('人物0'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('深层档案默认展示，形态切换采用对应资料', (tester) async {
    await pumpArchive(tester, detail: true);
    expect(find.text('隐藏身份'), findsOneWidget);
    expect(find.text('其他称呼：奇美拉（测试）'), findsOneWidget);
    expect(find.text('剧情秘密对白'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阿米娅（医疗） · 医疗').last);
    await tester.pumpAndSettle();
    expect(find.text('医疗档案'), findsOneWidget);
    expect(find.text('基础档案'), findsNothing);
  });

  testWidgets('旧数据标记不隐藏画廊立绘', (tester) async {
    final bundle = ArchiveBundle()
      ..detail = {
        ...detailJson(),
        'artCandidates': [
          {'kind': 'elite0', 'verified': true, 'spoiler': false},
          {'kind': 'elite2', 'verified': true, 'spoiler': true},
          {'kind': 'avg', 'verified': true},
        ],
      };
    await pumpArchive(tester, detail: true, bundle: bundle);
    await tester.tap(find.text('立绘'));
    await tester.pumpAndSettle();
    expect(find.text('基础立绘'), findsOneWidget);
    expect(find.text('精英二立绘'), findsOneWidget);
    expect(find.text('剧情立绘 3'), findsOneWidget);
  });
  testWidgets('展开篇章直接显示节选，回放传入正确位置', (tester) async {
    CharacterSnippet? clicked;
    await pumpArchive(
      tester,
      detail: true,
      replay: (story, snippet) async {
        clicked = snippet;
      },
    );
    await tester.tap(find.text('出场'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试篇章'));
    await tester.pumpAndSettle();
    expect(find.text('剧情秘密对白'), findsOneWidget);
    await tester.tap(find.text('回放此处'));
    await tester.pumpAndSettle();
    expect(clicked?.commandIndex, 3);
    expect(clicked?.line, 5);
  });

  testWidgets('资源加载失败显示重试入口并可恢复', (tester) async {
    final bundle = ArchiveBundle()..fail = true;
    await pumpArchive(tester, bundle: bundle);
    expect(find.text('人物档案暂时无法读取'), findsOneWidget);
    bundle.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('阿米娅'), findsOneWidget);
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets('宽度 $width 下双倍文字无溢出', (tester) async {
      await pumpArchive(tester, width: width, scale: 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await pumpArchive(tester, width: width, scale: 2, detail: true);
      expect(tester.takeException(), isNull);
    });
  }
}
