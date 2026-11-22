import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'asset_package.dart';
import 'asset_store.dart';
import 'cache_control.dart';
import 'export_target.dart';
import 'media_catalog.dart';

/// 单个文件导出失败的记录；失败不阻断其余文件。
class ExportFailure {
  const ExportFailure(this.uri, this.exportPath, this.error);
  final Uri uri;
  final String exportPath;
  final String error;

  @override
  String toString() => '$exportPath：$error';
}

class ExportResult {
  const ExportResult({
    required this.rootPath,
    required this.fileCount,
    required this.totalBytes,
    required this.failures,
    required this.manifest,
  });

  /// 实际写入的根目录（含自动序号，可能与预期名称不同）。
  final String rootPath;
  final int fileCount;
  final int totalBytes;
  final List<ExportFailure> failures;
  final Map<String, dynamic> manifest;

  bool get completed => failures.isEmpty;
}

/// 素材导出编排：逐文件取字节写入目标目录并生成 manifest。
/// 字节获取复用 AssetStore.loadTransient（缓存优先、不落缓存层），
/// 并发与暂停/取消沿用缓存任务的会话机制。
class StoryExporter {
  StoryExporter(this.store);
  final AssetStore store;

  Future<ExportResult> export({
    required ExportTarget target,
    required AssetPackage package,
    required Iterable<AssetItem> items,
    required String parentPath,
    String? appVersion,
    CacheControl? control,
    void Function(int done, int total, int bytes)? onProgress,
  }) async {
    final rootName = exportDirectoryName(
      groupName: package.groupName,
      title: package.storyTitle,
    );
    final rootPath = await target.createDirectory(parentPath, rootName);
    // 按「来源 + 目标路径」去重：同一来源用于不同分类（例如既作 CG 又作
    // 道具图）时目标路径不同，各写一份；同路径同来源只写一次。
    final seen = <String>{};
    final files = <(AssetItem, AssetFile)>[];
    for (final item in items) {
      for (final file in item.files) {
        if (seen.add('${file.uri}|${file.exportPath}')) {
          files.add((item, file));
        }
      }
    }
    var done = 0;
    var bytes = 0;
    final failures = <ExportFailure>[];
    final entries = <Map<String, dynamic>>[];
    for (final (item, file) in files) {
      await control?.checkpoint();
      try {
        final data = await store.loadTransient(
          file.uri,
          story: package.storyPath,
          alternates: file.alternates,
        );
        await target.writeFile(file.exportPath, data);
        bytes += data.length;
        entries.add({
          'path': file.exportPath,
          'kind': item.kind.name,
          'url': file.uri.toString(),
          'bytes': data.length,
          'sha256': sha256.convert(data).toString(),
        });
      } on CacheCancelled {
        rethrow;
      } catch (error) {
        failures.add(ExportFailure(file.uri, file.exportPath, '$error'));
      }
      onProgress?.call(++done, files.length, bytes);
    }
    final manifest = <String, dynamic>{
      'format': 1,
      'app': 'arknights_story_player',
      'version': ?appVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'story': {
        'path': package.storyPath,
        'title': package.storyTitle,
        'group': package.groupName,
        'entryType': package.entryType,
      },
      'files': entries,
      'unresolved': package.unresolved,
      if (failures.isNotEmpty)
        'failed': [
          for (final failure in failures)
            {
              'path': failure.exportPath,
              'url': failure.uri.toString(),
              'error': failure.error,
            },
        ],
    };
    try {
      await target.writeFile(
        'manifest.json',
        utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)),
      );
    } catch (error) {
      failures.add(
        ExportFailure(
          Uri.parse('https://local.invalid/export-manifest'),
          'manifest.json',
          '$error',
        ),
      );
    }
    return ExportResult(
      rootPath: rootPath,
      fileCount: entries.length,
      totalBytes: bytes,
      failures: failures,
      manifest: manifest,
    );
  }
}
