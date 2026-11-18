/// 非桌面平台暂不提供素材导出；菜单入口同时隐藏。
class ExportTarget {
  String? get rootPath => null;

  Future<String> createDirectory(String parentPath, String name) async =>
      throw UnsupportedError('当前平台不支持导出素材');

  Future<void> writeFile(String relativePath, List<int> bytes) async =>
      throw UnsupportedError('当前平台不支持导出素材');

  Future<void> deleteDirectory() async {}

  Future<void> openInFileManager() async =>
      throw UnsupportedError('当前平台不支持打开导出目录');
}
