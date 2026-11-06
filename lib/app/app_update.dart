import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_update_stub.dart' if (dart.library.io) 'app_update_io.dart';

export 'app_update_stub.dart'
    if (dart.library.io) 'app_update_io.dart'
    show UpdateFileStore;

/// 更新源仓库；项目主页、Issues 与发布页链接由它派生。
const String updateRepository = 'horizonzzzz/arknights-story-player';

abstract final class AppUpdateLinks {
  static final Uri project = Uri.parse('https://github.com/$updateRepository');
  static final Uri issues = Uri.parse(
    'https://github.com/$updateRepository/issues',
  );
  static final Uri releases = Uri.parse(
    'https://github.com/$updateRepository/releases',
  );
}

/// 一次 GitHub Release 描述的可用更新。
class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.notes,
    required this.pageUri,
    required this.assets,
  });

  /// 发布标签，例如 `v0.5.0`。
  final String version;

  /// 发布说明原文（Markdown）。
  final String notes;

  /// Release 页面地址。
  final Uri pageUri;

  /// 本次发布的可下载安装包。
  final List<AppUpdateAsset> assets;
}

class AppUpdateAsset {
  const AppUpdateAsset({
    required this.name,
    required this.uri,
    this.bytes,
  });

  /// 资产文件名，例如 `arknights_story_player-v0.5.0-windows-x64.zip`。
  final String name;
  final Uri uri;
  final int? bytes;
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 用户主动取消了更新下载。
class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();
}

/// 比较两个版本号，忽略 `v` 前缀、构建号与预发布后缀，只比较数字段。
/// `0.4` 与 `0.4.0` 相等；`0.4.0+4` 与 `0.4.0` 相等。
int compareVersions(String left, String right) {
  List<int> segments(String value) {
    final match = RegExp(
      r'^v?(\d+(?:\.\d+)*)',
    ).firstMatch(value.trim());
    return match == null
        ? const []
        : match
              .group(1)!
              .split('.')
              .map(int.parse)
              .toList();
  }

  final a = segments(left);
  final b = segments(right);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final difference = (i < a.length ? a[i] : 0) - (i < b.length ? b[i] : 0);
    if (difference != 0) return difference;
  }
  return 0;
}

/// 检查与下载 GitHub Release 更新。
///
/// 桌面平台支持应用内下载到系统下载目录；移动端与 Web 由调用方用
/// 系统浏览器或发布页获取安装包（[AppUpdateAsset.uri]）。
class AppUpdateClient {
  AppUpdateClient({
    http.Client? client,
    Uri? releasesApi,
    this.currentVersion,
    UpdateFileStore? files,
  }) : _client = client ?? http.Client(),
       _releasesApi =
           releasesApi ??
           Uri.parse(
             'https://api.github.com/repos/$updateRepository/releases/latest',
           ),
       files = files ?? const UpdateFileStore();

  final http.Client _client;
  final Uri _releasesApi;

  /// 当前版本号，例如 `0.4.0`；由调用方从 package_info 获取后写入。
  String? currentVersion;

  /// 文件系统后端，测试可注入自定义实现。
  final UpdateFileStore files;

  /// 检查最新发布：返回 [AppUpdate] 表示有可用更新，null 表示已是最新。
  /// 检查失败抛 [AppUpdateException]。
  Future<AppUpdate?> check() async {
    final current = currentVersion?.trim();
    if (current == null || current.isEmpty) {
      throw const AppUpdateException('无法读取当前版本号。');
    }
    http.Response response;
    try {
      response = await _client
          .get(
            _releasesApi,
            headers: {
              'accept': 'application/vnd.github+json',
              'user-agent': '$updateRepository-update-check',
            },
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const AppUpdateException('检查更新超时，请稍后重试。');
    } catch (_) {
      throw const AppUpdateException('无法连接更新服务器。');
    }
    if (response.statusCode == 404) {
      throw const AppUpdateException('尚未发布任何版本。');
    }
    if (response.statusCode != 200) {
      throw AppUpdateException('更新服务返回 HTTP ${response.statusCode}。');
    }
    final dynamic data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const AppUpdateException('更新信息格式异常。');
    }
    if (data is! Map<String, dynamic> || data['tag_name'] is! String) {
      throw const AppUpdateException('更新信息缺少版本号。');
    }
    final tag = data['tag_name'] as String;
    if (compareVersions(tag, current) <= 0) return null;
    final body = data['body'];
    final htmlUrl = data['html_url'];
    final assets = <AppUpdateAsset>[];
    final rawAssets = data['assets'];
    if (rawAssets is List) {
      for (final asset in rawAssets) {
        if (asset is Map<String, dynamic> &&
            asset['name'] is String &&
            asset['browser_download_url'] is String) {
          assets.add(
            AppUpdateAsset(
              name: asset['name'] as String,
              uri: Uri.parse(asset['browser_download_url'] as String),
              bytes: asset['size'] is int ? asset['size'] as int : null,
            ),
          );
        }
      }
    }
    return AppUpdate(
      version: tag,
      notes: body is String ? body : '',
      pageUri: htmlUrl is String
          ? Uri.parse(htmlUrl)
          : AppUpdateLinks.releases,
      assets: assets,
    );
  }

  /// 桌面应用内下载：写入系统下载目录并返回保存的文件路径。
  /// 下载被 [isCancelled] 打断时抛 [UpdateDownloadCancelled]；
  /// 其余失败抛 [AppUpdateException]，残留的临时文件会被清理。
  Future<String> download(
    AppUpdateAsset asset, {
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final directory = await files.downloadDirectory();
    if (directory == null) {
      throw const AppUpdateException('当前平台不支持应用内下载，请在发布页获取安装包。');
    }
    final target = files.join(directory, asset.name);
    final partial = '$target.part';
    var received = 0;
    var lastNotified = 0;
    try {
      final response = await _client
          .send(http.Request('GET', asset.uri))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw AppUpdateException('下载失败：HTTP ${response.statusCode}。');
      }
      final total = response.contentLength;
      await files.write(
        partial,
        response.stream.map((chunk) {
          if (isCancelled?.call() ?? false) {
            throw const UpdateDownloadCancelled();
          }
          received += chunk.length;
          // 进度按 256 KB 粒度汇报，避免大文件每个网络分块都触发界面重建。
          if (received - lastNotified >= 262144) {
            lastNotified = received;
            onProgress?.call(received, total);
          }
          return chunk;
        }),
      );
      if (isCancelled?.call() ?? false) throw const UpdateDownloadCancelled();
      if (total != null && received != total) {
        throw const AppUpdateException('下载不完整，请稍后重试。');
      }
      await files.move(partial, target);
      onProgress?.call(received, total);
      return target;
    } catch (_) {
      try {
        await files.remove(partial);
      } catch (_) {
        // 清理失败不掩盖原始错误。
      }
      rethrow;
    }
  }

  /// 在系统文件管理器中显示保存的更新包。
  Future<void> reveal(String path) => files.reveal(path);

  void close() => _client.close();
}
