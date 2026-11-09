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

  // 极小清单代替真实 176 MB 模型，验证多源下载/校验/安装链路。
  final hello = utf8.encode('hello');
  final abc = utf8.encode('abc');
  final testFiles = <VoicePackFile>[
    VoicePackFile('a.bin', 5, sha256.convert(hello).toString()),
    VoicePackFile('b.bin', 3, sha256.convert(abc).toString()),
  ];
  final helloPart = utf8.encode('he');

  String stagingPath() => '${root.path}/voice_packs/.downloading';
  String packPath() => '${root.path}/voice_packs/${VoicePackStore.id}';

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

  test('镜像损坏与安装记录异常都回到未安装状态', () async {
    final path = Directory('${root.path}/voice_packs')..createSync();
    File('${path.path}/bindings.json').writeAsStringSync('[]');
    Directory('${path.path}/${VoicePackStore.id}').createSync();
    File('${path.path}/${VoicePackStore.id}/installed.json').writeAsStringSync(
      jsonEncode({'version': 1, 'files': const {'model.int8.onnx': 'bad'}}),
    );
    final store = LocalVoicePackStore(supportDirectory: () async => root);
    await store.initialize();
    expect(store.status, VoicePackStatus.missing);
    expect(store.profile.resolve('阿米娅'), 3);
    expect(await validateVoicePack('${path.path}/missing', testFiles), 0);
    store.dispose();
  });

  test('镜像整坏时换官方源，逐文件校验通过后安装成功', () async {
    final store = LocalVoicePackStore(
      supportDirectory: () async => root,
      files: testFiles,
      clientFactory: () => MockClient((request) async {
        if (request.url.host == 'hf-mirror.com') {
          return http.Response('unavailable', 500);
        }
        expect(request.url.host, 'huggingface.co');
        return http.Response(
          request.url.path.endsWith('a.bin') ? 'hello' : 'abc',
          200,
        );
      }),
    );
    await store.install();
    expect(store.status, VoicePackStatus.installed, reason: store.error);
    expect(store.installedBytes, 8);
    expect(File('${packPath()}/a.bin').readAsBytesSync(), hello);
    expect(File('${packPath()}/b.bin').readAsBytesSync(), abc);
    expect(store.receivedBytes, 8);
    expect(Directory(stagingPath()).existsSync(), isFalse);
    store.dispose();
  });

  test('镜像文件被篡改时丢弃重下官方源', () async {
    var mirrorAttempts = 0;
    final store = LocalVoicePackStore(
      supportDirectory: () async => root,
      files: testFiles,
      clientFactory: () => MockClient((request) async {
        if (request.url.host == 'hf-mirror.com') {
          mirrorAttempts++;
          return http.Response('xyzzy', 200);
        }
        return http.Response(
          request.url.path.endsWith('a.bin') ? 'hello' : 'abc',
          200,
        );
      }),
    );
    await store.install();
    expect(store.status, VoicePackStatus.installed, reason: store.error);
    expect(mirrorAttempts, 2, reason: '每个文件都先试镜像，篡改内容丢弃 .part 后换源');
    expect(File('${packPath()}/a.bin').readAsStringSync(), 'hello');
    store.dispose();
  });

  test('续传发送 Range，206 拼接剩余字节完成，200 覆盖旧数据', () async {
    Directory(stagingPath()).createSync(recursive: true);
    File('${stagingPath()}/a.bin.part').writeAsBytesSync(helloPart);
    var sawRange = false;
    final store = LocalVoicePackStore(
      supportDirectory: () async => root,
      files: testFiles,
      clientFactory: () => MockClient((request) async {
        if (request.url.path.endsWith('a.bin')) {
          final range = request.headers['Range'];
          if (request.url.host == 'hf-mirror.com') {
            expect(range, 'bytes=2-');
            sawRange = true;
            return http.Response(
              'llo',
              206,
              headers: {'content-range': 'bytes 2-4/5'},
            );
          }
          expect(range, isNull);
          return http.Response('hello', 200);
        }
        return http.Response('abc', 200);
      }),
    );
    await store.install();
    expect(store.status, VoicePackStatus.installed, reason: store.error);
    expect(sawRange, isTrue);
    expect(File('${packPath()}/a.bin').readAsBytesSync(), hello);
    store.dispose();
  });

  test('全部源不可用时失败，错误的续传范围被拒绝且保留部分文件', () async {
    Directory(stagingPath()).createSync(recursive: true);
    File('${stagingPath()}/a.bin.part').writeAsBytesSync(helloPart);
    final store = LocalVoicePackStore(
      supportDirectory: () async => root,
      files: testFiles,
      clientFactory: () => MockClient((request) async {
        if (request.url.path.endsWith('a.bin')) {
          return http.Response(
            'bad',
            206,
            headers: {'content-range': 'bytes 0-2/3'},
          );
        }
        return http.Response('abc', 200);
      }),
    );
    await store.install();
    expect(store.status, VoicePackStatus.failed);
    expect(store.error, contains('a.bin'));
    expect(store.receivedBytes, 2, reason: 'b.bin 未完成前失败，进度只含 .part');
    expect(File('${stagingPath()}/a.bin.part').readAsBytesSync(), helloPart);
    store.dispose();
  });

  test('重启后继续未完成的下载：已就位文件跳过，进度包含 .part', () async {
    Directory(stagingPath()).createSync(recursive: true);
    File('${stagingPath()}/a.bin').writeAsBytesSync(hello);
    File('${stagingPath()}/b.bin.part').writeAsBytesSync(utf8.encode('ab'));
    final store = LocalVoicePackStore(
      supportDirectory: () async => root,
      files: testFiles,
      clientFactory: () => MockClient((request) async {
        expect(request.url.path.endsWith('a.bin'), isFalse,
            reason: '已就位文件不应重复下载');
        expect(request.headers['Range'], 'bytes=2-');
        return http.Response('c', 206,
            headers: {'content-range': 'bytes 2-2/3'});
      }),
    );
    await store.install();
    expect(store.status, VoicePackStatus.installed, reason: store.error);
    expect(store.receivedBytes, 8);
    expect(store.installedBytes, 8);
    store.dispose();
  });

  test('安装阶段清理 .part 残留，缺文件或大小不符直接失败', () async {
    final staging = Directory(stagingPath())..createSync(recursive: true);
    File('${staging.path}/a.bin').writeAsBytesSync(hello);
    File('${staging.path}/a.bin.part').writeAsBytesSync(helloPart);
    await expectLater(
      installDownloadedFiles(stagingPath(), '${root.path}/voice_packs',
          testFiles),
      throwsFormatException,
    );
    await Directory(stagingPath()).delete(recursive: true);
    final staging2 = Directory(stagingPath())..createSync(recursive: true);
    File('${staging2.path}/a.bin').writeAsBytesSync(hello);
    File('${staging2.path}/b.bin').writeAsBytesSync(utf8.encode('abcd'));
    await expectLater(
      installDownloadedFiles(stagingPath(), '${root.path}/voice_packs',
          testFiles),
      throwsFormatException,
    );
    expect(
      Directory('${root.path}/voice_packs/${VoicePackStore.id}')
          .existsSync(),
      isFalse,
    );
  });

  test('启动时逐文件校验，模型被改写后拒绝加载', () async {
    final model = Directory('${root.path}/model')..createSync();
    final hashes = <String, String>{};
    for (final file in testFiles) {
      final bytes = utf8.encode(file.name == 'a.bin' ? 'hello' : 'abc');
      File('${model.path}/${file.name}').writeAsBytesSync(bytes);
      hashes[file.name] = sha256.convert(bytes).toString();
    }
    File('${model.path}/installed.json').writeAsStringSync(
      jsonEncode({'version': 1, 'files': hashes}),
    );
    expect(await validateVoicePack(model.path, testFiles), 8);
    File('${model.path}/a.bin').writeAsStringSync('changed');
    expect(await validateVoicePack(model.path, testFiles), 0);
  });
}
