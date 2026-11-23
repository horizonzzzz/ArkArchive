import 'export_target_backend.dart';

/// Web 暂不提供素材导出；菜单入口同时隐藏（`store.supportsExport`）。
/// 接入下载能力时替换本实现，不要在 UI 层散落平台判断。
class ExportTarget {
  ExportTarget({ExportTargetBackend? backend});

  String? get rootPath => null;

  bool get supportsDirectorySelection => false;

  String destinationSummary(String parentPath, String rootName) =>
      '当前平台不支持导出素材';

  String describeCompletion(String rootPath) => '素材已导出';

  String get openActionLabel => '打开导出结果';

  Future<String> createDirectory(String parentPath, String name) async =>
      throw UnsupportedError('当前平台不支持导出素材');

  Future<void> writeFile(String relativePath, List<int> bytes) async =>
      throw UnsupportedError('当前平台不支持导出素材');

  Future<void> commit() async {}

  Future<void> deleteDirectory() async {}

  Future<void> openResult() async =>
      throw UnsupportedError('当前平台不支持打开导出结果');
}
