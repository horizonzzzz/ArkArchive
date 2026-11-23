/// 平台导出后端的统一契约。
///
/// 桌面写散文件目录（[ExportTargetBackend] 的桌面实现），Android 把素材
/// 流式打进 zip 并通过系统分享保存；UI 与导出编排只与 `ExportTarget`
/// 门面交互，不感知后端差异，也不要在界面层散落平台判断。
abstract class ExportTargetBackend {
  /// 导出结果的展示位置：桌面为实际目录路径，Android 为 zip 文件名。
  String? get rootPath;

  /// 是否允许用户选择导出位置（决定底栏「更改」按钮是否出现）。
  bool get supportsDirectorySelection;

  /// 底栏目的地提示；[rootName] 为「章节/标题」形式的导出根名。
  String destinationSummary(String parentPath, String rootName);

  /// 导出完成的提示文案；[rootPath] 为 [createDirectory] 的返回值。
  String describeCompletion(String rootPath);

  /// 完成后主操作的文案（打开文件夹 / 分享）。
  String get openActionLabel;

  /// 创建导出目标；[parentPath] 仅桌面实现使用，其余平台忽略。
  Future<String> createDirectory(String parentPath, String name);

  /// 写入一个文件；[relativePath] 固定以 `/` 分隔。
  Future<void> writeFile(String relativePath, List<int> bytes);

  /// 全部文件（含 manifest）写完后的收尾；无收尾工作的后端为空实现。
  Future<void> commit();

  /// 清理未完成的目标；取消导出时由调用方执行。
  Future<void> deleteDirectory();

  /// 打开导出结果（文件管理器或系统分享面板）。
  Future<void> openResult();
}
