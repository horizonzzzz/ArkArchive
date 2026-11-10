import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:arknights_story_player/app/character_archive_data.dart';
import 'package:arknights_story_player/app/character_replay.dart';
import 'package:arknights_story_player/story_player/story_player.dart';

import 'data_test.dart' show MemoryCache;

void main() {
  final story = CharacterStory('main/test', {'scriptHash': 'old'});
  CharacterSnippet snippet({
    int index = 1,
    int line = 2,
    String speaker = '阿米娅',
  }) => CharacterSnippet.fromJson({
    'commandIndex': index,
    'line': line,
    'speaker': speaker,
    'text': '目标台词',
  });
  StoryDocument document(String source, {String hash = 'old'}) => StoryDocument(
    title: '测试',
    script: StoryScript.parse(source),
    sourceHash: hash,
  );

  test('相同原始哈希使用精确指令位置，仍检查台词', () {
    final doc = document('开头\n[name="阿米娅"]目标台词');
    expect(locateCharacterReplay(doc, story, snippet()).commandIndex, 1);
    expect(
      locateCharacterReplay(doc, story, snippet(speaker: '其他人')).commandIndex,
      isNull,
    );
  });

  test('版本变化后使用原始行和唯一台词重新定位', () {
    final doc = document('// 新增注释\n开头\n[name="阿米娅"]目标台词', hash: 'new');
    final location = locateCharacterReplay(doc, story, snippet());
    expect(location.commandIndex, 1);
    expect(location.notice, contains('重新定位'));
    final changed = document('新增\n开头\n[name="阿米娅"]目标台词', hash: 'new');
    expect(locateCharacterReplay(changed, story, snippet()).commandIndex, 2);
  });

  test('重复台词只能由原始行消歧，不猜测最近位置', () {
    final doc = document('[name="阿米娅"]目标台词\n[name="阿米娅"]目标台词', hash: 'new');
    expect(locateCharacterReplay(doc, story, snippet(line: 1)).commandIndex, 0);
    expect(
      locateCharacterReplay(doc, story, snippet(line: 9)).commandIndex,
      isNull,
    );
    expect(
      locateCharacterReplay(document('其他台词'), story, snippet()).commandIndex,
      isNull,
    );
  });

  test('说话人使用与构建器一致的全角括号规范化', () {
    final doc = document('[name="人物（青年）"]目标台词');
    expect(
      locateCharacterReplay(
        doc,
        story,
        snippet(index: 0, line: 1, speaker: '人物(青年)'),
      ).commandIndex,
      0,
    );
  });

  test('剧情仓库保留原始字节哈希，而不是解析后的指令指纹', () async {
    final bytes = utf8.encode('// 注释\r\n[name="阿米娅"]目标台词\r\n');
    final store = AssetStore(
      cache: MemoryCache(),
      client: MockClient((_) async => http.Response.bytes(bytes, 200)),
    );
    addTearDown(store.close);
    final doc = await StoryRepository(store)
        .load(Uri.parse('https://example.test/story.txt'));
    expect(doc.sourceHash, sha256.convert(bytes).toString());
    expect(doc.sourceHash, isNot(PlaybackProgress.fingerprint(doc.script)));
  });
}
