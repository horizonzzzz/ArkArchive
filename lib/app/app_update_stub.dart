/// Web 等无 dart:io 平台的更新文件后端；应用内下载不可用，
/// 更新包由浏览器或发布页获取。接口形状与 app_update_io.dart 保持一致。
class UpdateFileStore {
  const UpdateFileStore();

  Future<String?> downloadDirectory() async => null;

  String join(String directory, String name) => '$directory/$name';

  Future<void> write(String path, Stream<List<int>> stream) async =>
      throw UnsupportedError('当前平台不支持应用内下载');

  Future<void> move(String from, String to) async =>
      throw UnsupportedError('当前平台不支持应用内下载');

  Future<void> remove(String path) async {}

  Future<void> reveal(String path) async =>
      throw UnsupportedError('当前平台不支持打开所在文件夹');
}
