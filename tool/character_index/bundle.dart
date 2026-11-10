import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'build.dart' show writeOutput;
import 'catalog.dart';

/// 将验收通过的快照打包为只读文本资源；不包含图片或下载缓存。
Future<String> bundleArchive(Directory source, Directory destination) async {
  Future<Map<String, dynamic>> read(String name) async => object(
    jsonDecode(await File('${source.path}/$name').readAsString()),
    name,
  );
  final report = await read('report.json');
  final index = await read('index.json');
  if (report['releaseReady'] != true ||
      object(index['coverage'], 'coverage')['complete'] != true ||
      report['generatedAt'] != index['generatedAt']) {
    throw StateError('仅允许打包完整且通过质量验收的同一批人物数据');
  }
  final details = <String, String>{};
  final hashes = <String, String>{};
  for (final value in array(index['people'], 'people')) {
    final person = object(value, 'person');
    final filename = detailFilename(person['id'] as String);
    if (person['detailFile'] != filename) {
      throw FormatException('详情引用不安全：${person['detailFile']}');
    }
    final detail = await read('details/$filename');
    if (detail['id'] != person['id'])
      throw FormatException('详情人物不匹配：$filename');
    details[filename] = jsonEncode(detail);
    hashes[filename] = sha256
        .convert(utf8.encode(details[filename]!))
        .toString();
  }
  index.remove('stage');
  final statistics = object(report['statistics'], 'statistics');
  final artwork = statistics['artVerification'];
  index['quality'] = {
    'namedLineCoverage': statistics['namedLineCoverage'],
    'top200NamedLineCoverage': statistics['top200NamedLineCoverage'],
    'operatorPortraitCoverage': artwork is Map
        ? artwork['operatorPortraitCoverage']
        : null,
  };
  // 版本只由内容决定，重复构建的生成时间不制造新版本。
  final stableIndex = Map<String, dynamic>.from(index)..remove('generatedAt');
  final version = sha256
      .convert(utf8.encode(jsonEncode([stableIndex, hashes])))
      .toString()
      .substring(0, 16);
  index['version'] = version;
  final indexText = jsonEncode(index);
  await writeOutput(destination, (directory) async {
    await Directory('${directory.path}/details').create();
    await File('${directory.path}/index.json').writeAsString(indexText);
    for (final entry in details.entries) {
      await File('${directory.path}/details/${entry.key}')
          .writeAsString(entry.value);
    }
    await File('${directory.path}/manifest.json').writeAsString(
      jsonEncode({
        'schema': 1,
        'version': version,
        'generatedAt': index['generatedAt'],
        'indexSha256': sha256.convert(utf8.encode(indexText)).toString(),
        'details': hashes,
        'attribution': 'PRTS Wiki / ArknightsGameResource',
      }),
    );
  });
  return version;
}

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      '用法：dart run tool/character_index/bundle.dart <构建目录> <文本资源目录>',
    );
    exitCode = 1;
    return;
  }
  try {
    final version = await bundleArchive(Directory(args[0]), Directory(args[1]));
    stdout.writeln('已打包人物档案版本 $version → ${args[1]}');
  } on Object catch (error) {
    stderr.writeln('人物档案打包失败：$error');
    exitCode = 1;
  }
}
