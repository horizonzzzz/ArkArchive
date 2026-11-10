import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../tool/character_index/build.dart';
import '../tool/character_index/catalog.dart';

void main() {
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('character-index-test-');
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test('CLI 校验冲突选项、数量范围和缺失值', () {
    for (final args in [
      ['--offline', '--refresh'],
      ['--limit', '0'],
      ['--limit', 'x'],
      ['--concurrency', '17'],
      ['--out'],
      ['--unknown'],
    ]) {
      expect(() => BuildOptions(args), throwsFormatException);
    }
    expect(BuildOptions([]).out, 'build/characters');
    expect(BuildOptions(['--limit', '8']).out, 'build/characters-sample');
    expect(BuildOptions(['--cache', 'tmp']).storiesCache, 'tmp/stories');
  });

  test('离线缓存不访问网络，缓存缺失时明确失败', () async {
    final client = MockClient((_) => throw StateError('不应访问网络'));
    addTearDown(client.close);
    final loader = SourceLoader(BuildOptions(['--offline']), client);
    final file = File('${temporary.path}/script.txt');
    final bytes = utf8.encode('[name=甲]台词');
    await file.writeAsBytes(bytes);
    expect(await loader.load(file, []), bytes);
    await file.delete();
    await expectLater(
      loader.load(file, []),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('读取缓存也校验 HTML 错误页、空文件和损坏 JSON', () async {
    final client = MockClient((_) => throw StateError('不应访问网络'));
    addTearDown(client.close);
    final loader = SourceLoader(BuildOptions(['--offline']), client);
    for (final (name, content) in [
      ('script.txt', '<html>错误页</html>'),
      ('empty.txt', ''),
      ('data.json', '{broken'),
    ]) {
      final file = File('${temporary.path}/$name');
      await file.writeAsString(content);
      await expectLater(loader.load(file, []), throwsFormatException);
    }
  });

  test('404 回退到下一源，缓存保存响应原字节', () async {
    final requested = <String>[];
    final bytes = utf8.encode('[name=甲]中文');
    final client = MockClient((request) async {
      requested.add(request.url.host);
      return request.url.host == 'first.example'
          ? http.Response('missing', 404)
          : http.Response.bytes(bytes, 200);
    });
    addTearDown(client.close);
    final loader = SourceLoader(BuildOptions([]), client);
    final file = File('${temporary.path}/nested/script.txt');
    expect(
      await loader.load(file, [
        Uri.parse('https://first.example/script'),
        Uri.parse('https://second.example/script'),
      ]),
      bytes,
    );
    expect(requested, ['first.example', 'second.example']);
    expect(await file.readAsBytes(), bytes);
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });

  test('刷新失败保留已有缓存', () async {
    final client = MockClient((_) async => http.Response('missing', 404));
    addTearDown(client.close);
    final loader = SourceLoader(BuildOptions(['--refresh']), client);
    final file = File('${temporary.path}/script.txt');
    await file.writeAsString('原始缓存');
    await expectLater(
      loader.load(file, [Uri.parse('https://missing.example/')]),
      throwsStateError,
    );
    expect(await file.readAsString(), '原始缓存');
  });

  test('产物替换删除旧详情，写入失败保留上次成功产物', () async {
    final output = Directory('${temporary.path}/nested/output');
    Future<void> put(Directory directory, String name, String value) async {
      await File('${directory.path}/$name').writeAsString(value);
    }

    await writeOutput(output, (stage) => put(stage, 'old.json', 'old'));
    await expectLater(
      writeOutput(output, (stage) async {
        await put(stage, 'partial.json', 'partial');
        throw StateError('模拟生成失败');
      }),
      throwsStateError,
    );
    expect(await File('${output.path}/old.json').readAsString(), 'old');
    expect(await File('${output.path}/partial.json').exists(), isFalse);
    await writeOutput(output, (stage) => put(stage, 'new.json', 'new'));
    expect(await File('${output.path}/old.json').exists(), isFalse);
    expect(await File('${output.path}/new.json').readAsString(), 'new');
    expect((await output.parent.list().toList()).length, 1);
  });

  test('相对路径产物目录支持重复构建', () async {
    final root = await Directory('build')
        .createTemp('character-index-relative-');
    addTearDown(() => root.delete(recursive: true));
    final output = Directory('${root.path}/output');
    Future<void> write(Directory stage) async {
      await File('${stage.path}/index.json').writeAsString('{}');
    }

    await writeOutput(output, write);
    await writeOutput(output, write);
    expect(await File('${output.path}/index.json').exists(), isTrue);
  });

  test('被监听的产物目录支持重复构建', () async {
    final output = Directory('${temporary.path}/watched');
    Future<void> write(Directory stage) async {
      await File('${stage.path}/index.json').writeAsString('{}');
    }

    await writeOutput(output, write);
    final watcher = output.watch().listen((_) {});
    try {
      await writeOutput(output, write);
      expect(await File('${output.path}/index.json').exists(), isTrue);
    } finally {
      await watcher.cancel();
    }
  });

  test('文件替换中途失败会恢复备份并移除新文件', () async {
    final output = Directory('${temporary.path}/rollback');
    await writeOutput(output, (stage) async {
      await File('${stage.path}/a.json').writeAsString('old');
      await Directory('${stage.path}/blocked').create();
    });
    await expectLater(
      writeOutput(output, (stage) async {
        await File('${stage.path}/a.json').writeAsString('new');
        await File('${stage.path}/added.json').writeAsString('added');
        await File('${stage.path}/blocked').writeAsString('文件不能替换目录');
      }),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File('${output.path}/a.json').readAsString(), 'old');
    expect(await File('${output.path}/added.json').exists(), isFalse);
    expect((await output.parent.list().toList()).length, 1);
  });

  test('非空且无构建标记的目录不能覆盖', () async {
    await File('${temporary.path}/important.txt').writeAsString('保留');
    await expectLater(
      writeOutput(temporary, (_) async {}),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File('${temporary.path}/important.txt').readAsString(), '保留');
  });

  test('详情文件名拒绝路径穿越，CSV 防止公式注入', () {
    expect(() => detailFilename('npc:../../secret'), throwsFormatException);
    expect(detailFilename('op:char_001_test'), 'op_char_001_test.json');
    expect(csvCell('=2+2'), startsWith(String.fromCharCodes([34, 39])));
    expect(csvCell('@name'), startsWith(String.fromCharCodes([34, 39])));
    final quote = String.fromCharCode(34);
    expect(csvCell('a${quote}b'), '${quote}a$quote${quote}b$quote');
  });
}
