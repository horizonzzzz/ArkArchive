import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../tool/character_index/artwork.dart';
import '../tool/character_index/bundle.dart';
import '../tool/character_index/catalog.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('character-assets-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('图片只接受正确域名和图片响应，离线校验复用成功缓存', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.method, 'HEAD');
      return http.Response(
        '',
        200,
        headers: {
          'content-type': request.url.path.endsWith('valid.png')
              ? 'image/png'
              : 'text/html',
        },
      );
    });
    final cache = File('${root.path}/images.json');
    final verifier = ArtworkVerifier(client, cache);
    expect(await verifier.verify('https://media.prts.wiki/valid.png'), isTrue);
    expect(await verifier.verify('https://media.prts.wiki/error.png'), isFalse);
    expect(await verifier.verify('https://example.com/valid.png'), isFalse);
    await verifier.save();
    final offline = ArtworkVerifier(client, cache, offline: true);
    await offline.load();
    expect(await offline.verify('https://media.prts.wiki/valid.png'), isTrue);
    expect(
      await offline.verify('https://media.prts.wiki/missing.png'),
      isFalse,
    );
    expect(calls, 2);
    client.close();
  });

  test('临时服务失败可以重试，404 会缓存', () async {
    var calls = 0;
    final verifier = ArtworkVerifier(
      MockClient((request) async {
        calls++;
        return http.Response(
          '',
          request.url.path.endsWith('gone.png') ? 404 : 503,
        );
      }),
      File('${root.path}/images.json'),
    );
    await verifier.verify('https://media.prts.wiki/gone.png');
    await verifier.verify('https://media.prts.wiki/gone.png');
    await verifier.verify('https://media.prts.wiki/busy.png');
    await verifier.verify('https://media.prts.wiki/busy.png');
    expect(calls, 3);
  });

  test('刷新图片时重新检查之前缓存的失败结果', () async {
    const url = 'https://media.prts.wiki/portrait.png';
    final cache = File('${root.path}/images.json');
    await cache.writeAsString(jsonEncode({url: false}));
    final person = ArchivePerson(
      id: 'op:char_test',
      kind: 'operator',
      name: '测试',
    );
    person.artCandidates.add({'kind': 'elite0', 'url': url, 'verified': false});
    final catalog = CharacterCatalog()..people[person.id] = person;
    final client = MockClient(
      (request) async =>
          http.Response('', 200, headers: {'content-type': 'image/png'}),
    );
    final verifier = ArtworkVerifier(client, cache, refresh: true);
    final result = await verifier.enrich(catalog);
    expect(result['operatorPortraitCoverage'], 1);
    expect(person.portrait?['verified'], isTrue);
    client.close();
  });

  Future<void> fixture({
    bool ready = true,
    String time = 'first',
    String filename = 'op_char_test.json',
  }) async {
    await Directory('${root.path}/source/details').create(recursive: true);
    await File('${root.path}/source/index.json').writeAsString(
      jsonEncode({
        'schema': 1,
        'stage': 'p0',
        'generatedAt': time,
        'coverage': {'complete': true},
        'people': [
          {'id': 'op:char_test', 'detailFile': filename},
        ],
      }),
    );
    await File('${root.path}/source/report.json').writeAsString(
      jsonEncode({
        'releaseReady': ready,
        'generatedAt': time,
        'statistics': {
          'namedLineCoverage': 0.8,
          'top200NamedLineCoverage': 0.95,
        },
      }),
    );
    await File('${root.path}/source/details/op_char_test.json').writeAsString(
      jsonEncode({'id': 'op:char_test', 'profile': [], 'appearances': []}),
    );
  }

  test('未通过数据验收不能生成客户端资源', () async {
    await fixture(ready: false);
    await expectLater(
      bundleArchive(
        Directory('${root.path}/source'),
        Directory('${root.path}/out'),
      ),
      throwsStateError,
    );
    expect(await Directory('${root.path}/out').exists(), isFalse);
  });

  test('产物包含校验和，版本不随生成时间变化', () async {
    await fixture();
    final source = Directory('${root.path}/source');
    final out = Directory('${root.path}/out');
    final first = await bundleArchive(source, out);
    await fixture(time: 'second');
    expect(await bundleArchive(source, out), first);
    final manifest = jsonDecode(
      await File('${out.path}/manifest.json').readAsString(),
    ) as Map;
    expect(manifest['version'], first);
    expect((manifest['indexSha256'] as String).length, 64);
    expect((manifest['details'] as Map).keys, ['op_char_test.json']);
    expect(await File('${out.path}/report.json').exists(), isFalse);
  });

  test('拒绝被替换的详情文件路径', () async {
    await fixture(filename: '../outside.json');
    await expectLater(
      bundleArchive(
        Directory('${root.path}/source'),
        Directory('${root.path}/out'),
      ),
      throwsFormatException,
    );
  });
}
