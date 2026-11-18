import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'media_catalog.dart';

/// 聚合后的导出条目：用户在导出界面上看到并勾选的一项。
/// 立绘的身体与表情差分、BGM 的前奏与循环体在物理上对应多个文件，
/// 但作为一个条目整体勾选，避免导出残缺组合。
class AssetItem {
  const AssetItem(this.id, this.kind, this.title, this.group, this.files);

  /// 稳定标识：类别 + 归属 + 名称。
  final String id;
  final AssetKind kind;
  final String title;
  final String group;
  final List<AssetFile> files;

  /// 预览主图：立绘取身体差分，BGM 取循环体，其余为文件本身。
  Uri get preview => files.first.uri;
}

/// 一篇剧情的完整素材清单：条目由 [AssetRef] 聚合，脚本由仓库补充。
class AssetPackage {
  AssetPackage({
    required this.storyTitle,
    required this.storyPath,
    required this.groupName,
    required this.entryType,
    required this.items,
    required this.unresolved,
  });

  factory AssetPackage.fromRefs({
    required String storyTitle,
    required String storyPath,
    required String groupName,
    required String entryType,
    required List<AssetRef> refs,
    required List<AssetFile> script,
    required List<String> unresolved,
  }) {
    // 路径定稿：逐段清洗，不同来源撞同一路径时用来源哈希后缀区分。
    // 定稿后的路径既用于写盘也写入 manifest，避免两者不一致；
    // 同一来源用于不同分类时路径不同，各自保留一份。
    final usedPaths = <String, Uri>{};
    AssetFile finalize(AssetFile file) {
      final base = _cleanExportPath(file.exportPath);
      final hash = sha256
          .convert(utf8.encode(file.uri.toString()))
          .toString()
          .substring(0, 8);
      var path = base;
      var attempt = 0;
      while (true) {
        final owner = usedPaths[path];
        if (owner == null || owner == file.uri) {
          usedPaths[path] = file.uri;
          return AssetFile(file.uri, path, alternates: file.alternates);
        }
        attempt++;
        path = _withHashSuffix(base, attempt == 1 ? hash : '$hash-$attempt');
      }
    }

    final items = <AssetItem>[];
    final index = <String, int>{};
    for (final ref in refs) {
      final files = [for (final file in ref.files) finalize(file)];
      final id = '${ref.kind.name}|${ref.group}|${ref.title}';
      final existing = index[id];
      if (existing == null) {
        index[id] = items.length;
        items.add(AssetItem(id, ref.kind, ref.title, ref.group, files));
      } else {
        final merged = items[existing].files;
        for (final file in files) {
          if (!merged.any((existing) => existing.uri == file.uri)) {
            merged.add(file);
          }
        }
      }
    }
    if (script.isNotEmpty) {
      final finalized = [for (final file in script) finalize(file)];
      final name = finalized.first.exportPath.split('/').last;
      items.add(
        AssetItem(
          'script|',
          AssetKind.script,
          name,
          '',
          List.unmodifiable(finalized),
        ),
      );
    }
    return AssetPackage(
      storyTitle: storyTitle,
      storyPath: storyPath,
      groupName: groupName,
      entryType: entryType,
      items: List.unmodifiable(items),
      unresolved: List.unmodifiable(unresolved),
    );
  }

  final String storyTitle;
  final String storyPath;
  final String groupName;
  final String entryType;
  final List<AssetItem> items;
  final List<String> unresolved;

  /// 实际写入的文件数：按「来源 + 目标路径」去重。同一文件被多个条目
  /// 引用且目标路径相同时只写一次；同一来源用于不同分类时各写一份。
  int get fileCount => {
    for (final item in items)
      for (final file in item.files) '${file.uri}|${file.exportPath}',
  }.length;

  List<AssetItem> itemsOfKinds(Set<AssetKind> kinds) => [
    for (final item in items)
      if (kinds.contains(item.kind)) item,
  ];
}

/// 清洗文件名中的平台非法字符；开头结尾的点与空格对 Windows 同样
/// 有害（结尾非法、开头易在复制粘贴中丢失），一并去除。
String sanitizeFileName(String name) {
  var cleaned = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  cleaned = cleaned.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
  return cleaned.isEmpty ? '_' : cleaned;
}

/// 导出根目录名：`章节/标题` 两段；章节为空时直接使用标题。
String exportDirectoryName({required String groupName, required String title}) {
  final segments = [
    if (groupName.trim().isNotEmpty) sanitizeFileName(groupName.trim()),
    sanitizeFileName(title.trim()),
  ];
  return segments.join('/');
}

String _cleanExportPath(String path) {
  final cleaned = path
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .map(sanitizeFileName)
      .join('/');
  return cleaned.isEmpty ? 'extras/asset' : cleaned;
}

/// 在扩展名前插入短哈希，保持目录结构与可读文件名。
String _withHashSuffix(String path, String suffix) {
  final slash = path.lastIndexOf('/');
  final dir = slash >= 0 ? path.substring(0, slash + 1) : '';
  final name = path.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final extension = dot > 0 ? name.substring(dot) : '';
  return '$dir${stem}_$suffix$extension';
}