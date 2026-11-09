import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:arknights_story_player/story_player/data/voice_pack.dart';
import 'package:arknights_story_player/story_player/data/voice_pack_io.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('voice_pack_test');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('角色映射跨实例保存，删除模型保留角色选择', () async {
    final store = LocalVoicePackStore(supportDirectory: () async => root);
    await store.bind('阿米娅', 58);
    await store.remove();
    final restored = LocalVoicePackStore(supportDirectory: () async => root);
    await restored.initialize();
    expect(restored.profile.resolve('阿米娅'), 58);
    await restored.bind('阿米娅', null);
    expect(restored.profile.resolve('阿米娅'), 3);
    await expectLater(restored.bind('阿米娅', 2), throwsArgumentError);
    store.dispose();
    restored.dispose();
  });

  test('损坏的映射与安装记录回到未安装状态', () async {
    final path = Directory('${root.path}/voice_packs')..createSync();
    File('${path.path}/bindings.json').writeAsStringSync('[]');
    final store = LocalVoicePackStore(supportDirectory: () async => root);
    await store.initialize();
    expect(store.status, VoicePackStatus.missing);
    expect(store.profile.resolve('阿米娅'), 3);
    expect(await validateVoicePack('${path.path}/missing'), 0);
    store.dispose();
  });

  test('下载续传发送 Range，服务器返回完整内容时覆盖旧数据', () async {
    final path = Directory('${root.path}/voice_packs')..createSync();
    final partial = File('${path.path}/model.tar.bz2.part')
      ..writeAsStringSync('old');
    final store = LocalVoicePackStore(
      supportDirectory: () async => root,
      clientFactory: () => MockClient((request) async {
        expect(request.headers['Range'], 'bytes=3-');
        return http.Response('new', 200);
      }),
    );
    await store.install();
    expect(store.status, VoicePackStatus.failed);
    expect(partial.readAsStringSync(), 'new');
    expect(store.receivedBytes, 3);
    expect(store.directory, isNull);
    store.dispose();
  });

  test('错误续传范围被拒绝，原来的部分文件保留', () async {
    final path = Directory('${root.path}/voice_packs')..createSync();
    final partial = File('${path.path}/model.tar.bz2.part')
      ..writeAsStringSync('old');
    final store = LocalVoicePackStore(
      supportDirectory: () async => root,
      clientFactory: () => MockClient(
        (request) async => http.Response(
          'bad',
          206,
          headers: {'content-range': 'bytes 0-2/3'},
        ),
      ),
    );
    await store.install();
    expect(store.error, contains('续传范围不匹配'));
    expect(partial.readAsStringSync(), 'old');
    store.dispose();
  });

  test('校验失败清除坏包，不生成安装目录', () async {
    final packed = File('${root.path}/bad.tar.bz2')
      ..writeAsStringSync('corrupt');
    await expectLater(
      installVoiceArchive(packed.path, root.path),
      throwsFormatException,
    );
    expect(packed.existsSync(), isFalse);
    expect(
      Directory('${root.path}/${VoicePackStore.id}').existsSync(),
      isFalse,
    );
    for (final name in ['../model', '/model', 'C:/model', r'a\..\model']) {
      expect(safeVoicePath(name), isFalse, reason: name);
    }
  });

  test('启动时逐文件校验，模型被改写后拒绝加载', () async {
    final model = Directory('${root.path}/model')..createSync();
    final hashes = <String, String>{};
    for (final name in [
      'model.int8.onnx',
      'voices.bin',
      'tokens.txt',
      'lexicon-zh.txt',
      'lexicon-us-en.txt',
    ]) {
      final bytes = utf8.encode(name);
      File('${model.path}/$name').writeAsBytesSync(bytes);
      hashes[name] = sha256.convert(bytes).toString();
    }
    File('${model.path}/installed.json').writeAsStringSync(
      jsonEncode({
        'archiveSha256': VoicePackStore.archiveSha256,
        'files': hashes,
      }),
    );
    expect(await validateVoicePack(model.path), greaterThan(0));
    File('${model.path}/model.int8.onnx').writeAsStringSync('changed');
    expect(await validateVoicePack(model.path), 0);
  });
}
