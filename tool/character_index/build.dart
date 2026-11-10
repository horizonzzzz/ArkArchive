import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'catalog.dart';

const _help = '''人物档案 P0 数据构建（不发布生产 manifest）
dart run tool/character_index/build.dart [选项]
  --cache DIR           下载缓存，默认 .cache/character-archive
  --stories-cache DIR   剧情缓存，默认 <cache>/stories
  --npc-page FILE       使用本地 PRTS HTML 或 API JSON 快照
  --out DIR             专用产物目录，默认 build/characters（样本默认加 -sample）
  --limit N             只扫描前 N 篇，报告明确标记为样本
  --concurrency N       下载并发 1–16，默认 8
  --offline             仅用缓存，缓存缺失时失败
  --refresh             重新获取上游数据，不与 --offline 同用
  --help                显示帮助
''';

class BuildOptions {
  BuildOptions(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      final key = args[i];
      if (['--help', '--offline', '--refresh'].contains(key)) {
        flags.add(key);
      } else if ([
        '--cache',
        '--stories-cache',
        '--npc-page',
        '--out',
        '--limit',
        '--concurrency',
      ].contains(key)) {
        if (++i >= args.length || args[i].startsWith('--')) {
          throw FormatException('$key 缺少参数');
        }
        values[key] = args[i];
      } else {
        throw FormatException('未知选项：$key');
      }
    }
    if (offline && refresh) {
      throw const FormatException('--offline 与 --refresh 不能同用');
    }
    for (final key in ['--limit', '--concurrency']) {
      if (!values.containsKey(key)) continue;
      final value = int.tryParse(values[key]!);
      if (value == null ||
          value < 1 ||
          (key == '--concurrency' && value > 16)) {
        throw FormatException('$key 必须是有效正整数（并发最大 16）');
      }
    }
  }

  final Map<String, String> values = {};
  final Set<String> flags = {};
  String get cache => values['--cache'] ?? '.cache/character-archive';
  String get storiesCache => values['--stories-cache'] ?? '$cache/stories';
  String get out =>
      values['--out'] ??
      (limit == null ? 'build/characters' : 'build/characters-sample');
  bool get offline => flags.contains('--offline');
  bool get refresh => flags.contains('--refresh');
  int get concurrency => int.parse(values['--concurrency'] ?? '8');
  int? get limit => int.tryParse(values['--limit'] ?? '');
}

/// 缓存保留原始字节，脚本校验和与播放器读取的文件保持一致。
class SourceLoader {
  SourceLoader(this.options, this.client);
  final BuildOptions options;
  final http.Client client;
  final Map<String, dynamic> sources = {};
  static final excelBase = Uri.parse(
    'https://torappu.prts.wiki/gamedata/latest/excel/',
  );
  static final storyBases = [
    Uri.parse('https://torappu.prts.wiki/gamedata/latest/story/'),
    Uri.parse(
      'https://cdn.jsdelivr.net/gh/yuanyan3060/ArknightsGameResource@main/gamedata/story/',
    ),
    Uri.parse(
      'https://raw.githubusercontent.com/yuanyan3060/ArknightsGameResource/main/gamedata/story/',
    ),
  ];

  void _validate(List<int> bytes, String path) {
    final text = utf8.decode(bytes).replaceFirst(RegExp(r'^﻿'), '').trim();
    if (text.isEmpty || text.startsWith('<')) {
      throw FormatException('缓存或数据源返回空内容或 HTML：$path');
    }
    if (path.endsWith('.json')) jsonDecode(text);
  }

  Future<List<int>> load(File file, List<Uri> candidates) async {
    if (!options.refresh && await file.exists()) {
      final bytes = await file.readAsBytes();
      _validate(bytes, file.path);
      return bytes;
    }
    if (options.offline) throw FileSystemException('离线缓存缺失', file.path);
    Object? failure;
    for (final uri in candidates) {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final response = await client
              .get(
                uri,
                headers: {'User-Agent': 'ArkArchive-CharacterIndex/1.0'},
              )
              .timeout(const Duration(seconds: 30));
          if (response.statusCode == 404) {
            failure = HttpException('HTTP 404', uri: uri);
            break;
          }
          if (response.statusCode != 200) {
            throw HttpException('HTTP ${response.statusCode}', uri: uri);
          }
          _validate(response.bodyBytes, file.path);
          await file.parent.create(recursive: true);
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsBytes(response.bodyBytes, flush: true);
          if (await file.exists()) await file.delete();
          await temporary.rename(file.path);
          return response.bodyBytes;
        } on Exception catch (error) {
          failure = error;
          if (attempt < 2) {
            await Future<void>.delayed(
              Duration(milliseconds: 300 * (attempt + 1)),
            );
          }
        }
      }
    }
    throw StateError('获取失败：${candidates.first}；$failure');
  }

  Future<Map<String, dynamic>> excel(String filename) async {
    final uri = excelBase.resolve(filename);
    final bytes = await load(File('${options.cache}/$filename'), [uri]);
    sources[filename] = {
      'url': uri.toString(),
      'sha256': sha256.convert(bytes).toString(),
    };
    return object(jsonDecode(utf8.decode(bytes)), filename);
  }

  Future<String> npcPage() async {
    final local = options.values['--npc-page'];
    final uri = Uri.https('prts.wiki', '/api.php', {
      'action': 'parse',
      'format': 'json',
      'prop': 'text',
      'page': '剧情角色一览',
    });
    final bytes = local == null
        ? await load(File('${options.cache}/npc_page_response.json'), [uri])
        : await File(local).readAsBytes();
    sources['npc'] = {
      'url': uri.toString(),
      'snapshot': local != null,
      'sha256': sha256.convert(bytes).toString(),
    };
    final text = utf8.decode(bytes);
    if (text.trimLeft().startsWith('<')) return text;
    final data = object(jsonDecode(text), 'NPC API');
    final parsed = object(data['parse'], 'NPC parse');
    final content = object(parsed['text'], 'NPC text')['*'];
    if (content is! String || content.isEmpty) {
      throw const FormatException('NPC API 未返回页面内容');
    }
    return content;
  }

  Future<List<int>> story(String path) => load(
    File('${options.storiesCache}/$path.txt'),
    storyBases.map((base) => base.resolve('$path.txt')).toList(),
  );
}

Future<void> parallelFor<T>(
  List<T> items,
  int concurrency,
  Future<void> Function(T) action,
) async {
  var next = 0;
  await Future.wait([
    for (var worker = 0; worker < concurrency; worker++)
      () async {
        while (next < items.length) {
          final item = items[next++];
          await action(item);
        }
      }(),
  ]);
}

Future<void> writeJson(File file, Object value) => file
    .writeAsString('${const JsonEncoder.withIndent('  ').convert(value)}\n')
    .then((_) {});

/// 先完整生成再替换；保留根目录以兼容 Windows 的目录监听，替换失败时恢复备份。
Future<void> writeOutput(
  Directory output,
  Future<void> Function(Directory) write,
) async {
  const marker = '.character-index-output';
  if (await output.exists() &&
      !await File('${output.path}/$marker').exists() &&
      !await output.list().isEmpty) {
    throw FileSystemException('产物目录非空且不是本工具创建的目录', output.path);
  }
  await output.parent.create(recursive: true);
  final stage = await output.parent.createTemp('.character-index-stage-');
  Directory? backup;
  var keepBackup = false;
  String relative(File file, Directory root) =>
      file.path.substring(root.path.length).replaceFirst(RegExp(r'^[/\\]'), '');
  Future<List<File>> files(Directory root) async {
    final entries = await root
        .list(recursive: true, followLinks: false)
        .toList();
    if (entries.any((entry) => entry is Link)) {
      throw FileSystemException('产物目录不能包含符号链接', root.path);
    }
    return entries.whereType<File>().toList();
  }

  try {
    await write(stage);
    await File('${stage.path}/$marker').writeAsString('character-index-p0\n');
    if (!await output.exists()) {
      await stage.rename(output.path);
      return;
    }
    final originals = await files(output);
    final replacements = await files(stage);
    backup = await output.parent.createTemp('.character-index-backup-');
    for (final original in originals) {
      final saved = File('${backup.path}/${relative(original, output)}');
      await saved.parent.create(recursive: true);
      await original.copy(saved.path);
    }
    final installed = <File>[];
    final names = replacements.map((file) => relative(file, stage)).toSet();
    try {
      for (final replacement in replacements) {
        final target = File('${output.path}/${relative(replacement, stage)}');
        await target.parent.create(recursive: true);
        await replacement.rename(target.path);
        installed.add(target);
      }
      for (final original in originals) {
        if (!names.contains(relative(original, output))) {
          await original.delete();
        }
      }
    } on Object catch (error, stack) {
      try {
        for (final file in installed) {
          if (await file.exists()) await file.delete();
        }
        for (final original in originals) {
          await File('${backup.path}/${relative(original, output)}')
              .copy(original.path);
        }
      } on Object catch (restoreError) {
        keepBackup = true;
        throw FileSystemException('恢复失败：$restoreError；旧产物保留在备份目录', backup.path);
      }
      Error.throwWithStackTrace(error, stack);
    }
  } finally {
    if (await stage.exists()) await stage.delete(recursive: true);
    if (backup != null && !keepBackup) await backup.delete(recursive: true);
  }
}

Future<int> buildArchive(BuildOptions options, http.Client client) async {
  final loader = SourceLoader(options, client);
  final catalog = CharacterCatalog();
  final dataDirectory = File.fromUri(Platform.script).parent.parent.uri
      .resolve('data/');
  Future<dynamic> config(String name) async => jsonDecode(
    await File.fromUri(dataDirectory.resolve(name)).readAsString(),
  );
  catalog.blocklist.addAll(
    (await File.fromUri(dataDirectory.resolve('character_blocklist.txt'))
            .readAsLines())
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .map(normalizedName),
  );
  stdout.writeln('加载干员、官方形态关系、档案与剧情目录…');
  catalog.loadOperators(
    characters: await loader.excel('character_table.json'),
    patches: await loader.excel('char_patch_table.json'),
    handbook: await loader.excel('handbook_info_table.json'),
    merges: array(await config('form_merge.json'), 'form_merge'),
  );
  catalog.loadNpcs(await loader.npcPage());
  final aliases = object(
    await config('character_aliases.json'),
    'character_aliases',
  );
  catalog.loadAliases(aliases);
  catalog.loadStories(await loader.excel('story_review_table.json'));
  // 人工归属表也属于构建输入，修改后必须能从报告追溯。
  for (final name in [
    'form_merge.json',
    'character_aliases.json',
    'character_blocklist.txt',
  ]) {
    loader.sources[name] = {
      'sha256': sha256
          .convert(
            await File.fromUri(dataDirectory.resolve(name)).readAsBytes(),
          )
          .toString(),
    };
  }
  final paths = catalog.stories.keys
      .take(options.limit ?? catalog.stories.length)
      .toList();
  final scripts = <String, List<int>>{};
  final failures = <String, String>{};
  var done = 0;
  // 下载可并行，扫描按目录顺序，保证样本与未归属示例不受网络完成顺序影响。
  for (var start = 0; start < paths.length; start += options.concurrency) {
    final batch = paths.skip(start).take(options.concurrency).toList();
    await parallelFor(batch, options.concurrency, (path) async {
      try {
        scripts[path] = await loader.story(path);
      } on Object catch (error) {
        failures[path] = error.toString();
      }
    });
    for (final path in batch) {
      final bytes = scripts.remove(path);
      if (bytes != null) {
        try {
          catalog.scanStory(path, bytes);
        } on Object catch (error) {
          failures[path] = error.toString();
        }
      }
      done++;
    }
    if (done % 80 == 0 || done == paths.length) {
      stdout.writeln('扫描 $done/${paths.length}；失败 ${failures.length}');
    }
  }
  catalog.sortAppearances();
  final statistics = catalog.statistics();
  final complete = failures.isEmpty && paths.length == catalog.stories.length;
  final generatedAt = DateTime.now().toUtc().toIso8601String();
  final coverage = {
    'scope': 'story_review_table',
    'complete': complete,
    'sample': paths.length < catalog.stories.length,
    'expectedStories': catalog.stories.length,
    'scannedStories': statistics['scannedStories'],
    'failedStories': failures.length,
  };
  final report = {
    'schema': 1,
    'stage': 'p0',
    'generatedAt': generatedAt,
    'coverage': coverage,
    'statistics': statistics,
    'sources': loader.sources,
    'failures': failures,
    'unmatchedSpeakers': catalog.unmatchedSpeakers,
    'excludedNpcs': catalog.excludedNpcs,
    'npcOperatorOverlaps': catalog.npcOperatorOverlaps,
    'mergeCandidates': catalog.mergeCandidates,
    'releaseReady': false,
    'remainingGates': [
      '人工复核 Top 200 未归属说话人与全部异格候选',
      '全量带名台词覆盖率 ≥ 70%，Top 200 带名台词覆盖率 ≥ 90%',
      '立绘有效性探测及干员立绘覆盖率 ≥ 95%',
      '干员剧情 AVG 形象归属、中文阵营标签与发布 manifest',
    ],
  };
  final outputPath = failures.isEmpty ? options.out : '${options.out}-failed';
  await writeOutput(Directory(outputPath), (directory) async {
    final details = await Directory('${directory.path}/details').create();
    final indexPeople = catalog.includedPeople;
    for (final entry in indexPeople) {
      final person = catalog.people[entry['id']]!;
      await writeJson(
        File('${details.path}/${entry['detailFile']}'),
        person.toDetail(),
      );
    }
    await writeJson(File('${directory.path}/index.json'), {
      'schema': 1,
      'stage': 'p0',
      'generatedAt': generatedAt,
      'coverage': coverage,
      'counts': {
        'people': statistics['people'],
        'operators': statistics['operators'],
        'npcs': statistics['npcs'],
      },
      'people': indexPeople,
      'stories': catalog.stories,
    });
    await writeJson(File('${directory.path}/report.json'), report);
    await File('${directory.path}/unmatched_speakers.csv')
        .writeAsString(unmatchedCsv(catalog.unmatchedSpeakers));
  });
  stdout.writeln(
    jsonEncode({
      'out': outputPath,
      'coverage': coverage,
      'statistics': statistics,
    }),
  );
  return failures.isEmpty ? 0 : 1;
}

Future<void> main(List<String> args) async {
  http.Client? client;
  try {
    final options = BuildOptions(args);
    if (options.flags.contains('--help')) {
      stdout.write(_help);
      return;
    }
    client = http.Client();
    exitCode = await buildArchive(options, client);
  } on Object catch (error) {
    stderr.writeln('人物档案构建失败：$error');
    exitCode = 1;
  } finally {
    client?.close();
  }
}
