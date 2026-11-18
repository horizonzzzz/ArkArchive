import 'dart:io';

import 'asset_package.dart';

/// 桌面端导出目标：把素材写入用户选择的目录。
/// 目录名与文件名在写入前统一清洗；末层目录已存在时追加序号，
/// 不覆盖任何已有内容。
class ExportTarget {
  ExportTarget({
    Future<void> Function(String executable, List<String> arguments)?
    startProcess,
  }) : _startProcess =
           startProcess ??
           ((executable, arguments) async {
             await Process.start(executable, arguments);
           });

  final Future<void> Function(String, List<String>) _startProcess;
  Directory? _root;

  String? get rootPath => _root?.path;

  Future<String> createDirectory(String parentPath, String name) async {
    final parent = Directory(parentPath);
    if (!await parent.exists()) {
      // 默认导出路径（如「下载/方舟档案室」）由应用拼接而来、此前不存在；
      // 与「章节」中间层一致地递归创建，首次导出无需用户先选目录。
      await parent.create(recursive: true);
    }
    final segments = name
        .split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .map(sanitizeFileName)
        .toList();
    if (segments.isEmpty) throw ArgumentError('导出目录名为空');
    var current = parent;
    for (var i = 0; i < segments.length - 1; i++) {
      current = Directory(_join(current.path, segments[i]));
      await current.create(recursive: true);
    }
    var last = segments.last;
    var candidate = Directory(_join(current.path, last));
    var index = 1;
    while (await candidate.exists()) {
      index++;
      candidate = Directory(_join(current.path, '$last ($index)'));
    }
    await candidate.create();
    _root = candidate;
    return candidate.path;
  }

  Future<void> writeFile(String relativePath, List<int> bytes) async {
    final root = _root;
    if (root == null) throw StateError('尚未创建导出目录');
    final segments = relativePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(sanitizeFileName)
        .toList();
    if (segments.isEmpty) throw ArgumentError('导出文件路径为空');
    var path = root.path;
    for (var i = 0; i < segments.length - 1; i++) {
      path = _join(path, segments[i]);
      await Directory(path).create(recursive: true);
    }
    final file = File(_join(path, segments.last));
    // 临时文件写完后重命名，中断不会留下半成品。
    final scratch = await Directory(path).createTemp('.export-');
    try {
      final temporary = File(_join(scratch.path, 'asset'));
      await temporary.writeAsBytes(bytes, flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    } finally {
      await scratch.delete(recursive: true);
    }
  }

  Future<void> deleteDirectory() async {
    final root = _root;
    _root = null;
    if (root != null && await root.exists()) {
      await root.delete(recursive: true);
    }
  }

  Future<void> openInFileManager() async {
    final root = _root;
    if (root == null) throw StateError('尚未创建导出目录');
    final path = await root.resolveSymbolicLinks();
    if (Platform.isWindows) {
      await _startProcess('explorer.exe', ['/n,', path]);
    } else if (Platform.isMacOS) {
      await _startProcess('open', [path]);
    } else if (Platform.isLinux) {
      await _startProcess('xdg-open', [path]);
    } else {
      throw UnsupportedError('当前平台不支持打开导出目录');
    }
  }
}

String _join(String a, String b) => '$a${Platform.pathSeparator}$b';
