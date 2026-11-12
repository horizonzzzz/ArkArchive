import 'dart:async';
import 'dart:convert';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import 'app_update_stub.dart' if (dart.library.io) 'app_update_io.dart';

export 'app_update_stub.dart'
    if (dart.library.io) 'app_update_io.dart'
    show UpdateFileStore, detectAndroidAbi;

/// 更新源仓库；项目主页、Issues 与发布页链接由它派生。
const String updateRepository = 'horizonzzzz/ArkArchive';

/// Android 安装包文件名上常见的架构标识，按设备主架构匹配。
const List<String> androidAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'];

/// 公开 GitHub 加速代理前缀；下载带有 sha256 的 GitHub 资产时按序尝试，直连 GitHub 兜底。
/// 代理站点可用性随时间波动，失效时在此列表直接增删维护即可。
const List<String> githubProxyPrefixes = [
  'https://gh-proxy.com/',
  'https://ghproxy.net/',
  'https://ghfast.top/',
];

abstract final class AppUpdateLinks {
  static final Uri project = Uri.parse('https://github.com/$updateRepository');
  static final Uri issues = Uri.parse(
    'https://github.com/$updateRepository/issues',
  );
  static final Uri releases = Uri.parse(
    'https://github.com/$updateRepository/releases',
  );

  /// Release Atom 订阅；GitHub API 被匿名限流（常见于代理/VPN 共享出口 IP
  /// 触发 403）或网络异常时，作为检查更新的备用通道。
  static final Uri releasesAtom = Uri.parse(
    'https://github.com/$updateRepository/releases.atom',
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
    this.sha256,
  });

  /// 资产文件名，例如 `arknights_story_player-v0.5.0-windows-x64.zip`。
  final String name;
  final Uri uri;

  /// 资产大小（字节）；备用通道构造的资产没有该信息。
  final int? bytes;

  /// GitHub API `digest` 字段提供的 sha256；下载完成后校验，防止公开代理
  /// 这类第三方通道篡改内容。
  final String? sha256;
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message, {this.definitive = false});
  final String message;

  /// 结论确定（尚未发布、缺少版本号）时不再尝试备用通道。
  final bool definitive;

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
    final match = RegExp(r'^v?(\d+(?:\.\d+)*)').firstMatch(value.trim());
    return match == null
        ? const []
        : match.group(1)!.split('.').map(int.parse).toList();
  }

  final a = segments(left);
  final b = segments(right);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final difference = (i < a.length ? a[i] : 0) - (i < b.length ? b[i] : 0);
    if (difference != 0) return difference;
  }
  return 0;
}

/// 从 Release Atom 条目链接提取版本标签，跳过非版本发布。
(String, String)? _firstAtomEntry(String document) {
  final repository = updateRepository.split('/');
  final version = RegExp(
    r'^v?\d+(?:\.\d+)*(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
  );
  for (final entry in html.parse(document).querySelectorAll('entry')) {
    for (final link in entry.querySelectorAll('link')) {
      final uri = Uri.tryParse(link.attributes['href'] ?? '');
      if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
        continue;
      }
      final parts = uri.pathSegments;
      if (parts.length != 5 ||
          parts[0] != repository[0] ||
          parts[1] != repository[1] ||
          parts[2] != 'releases' ||
          parts[3] != 'tag' ||
          !version.hasMatch(parts[4])) {
        continue;
      }
      return (
        parts[4],
        _atomPlainText(entry.querySelector('content')?.text ?? ''),
      );
    }
  }
  return null;
}

/// 订阅里的说明是 HTML；去除标签得到近似纯文本用于展示。
String _atomPlainText(String html) {
  final text = html
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'<[^>]*>'), ' ');
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 按工作流产物命名约定构造下载链接；命名规则变化时必须与
/// `.github/workflows/build.yml` 一起维护。该路径的资产没有大小与 sha256。
List<AppUpdateAsset> _conventionalAssets(String tag) {
  final version = (tag.startsWith('v') ? tag.substring(1) : tag)
      .split('+')
      .first;
  const base = 'arknights_story_player';
  final names = <String>[
    '$base-v$version-android-arm64-v8a.apk',
    '$base-v$version-android-armeabi-v7a.apk',
    '$base-v$version-android-x64.apk',
    '$base-v$version-android-universal.apk',
    '$base-v$version-windows-x64.zip',
    '$base-v$version-windows-x64-setup.exe',
    '$base-v$version-linux-x64.deb',
    '$base-v$version-linux-x64.AppImage',
    '$base-v$version-linux-x64.tar.gz',
    '$base-v$version-linux-arm64.deb',
    '$base-v$version-linux-arm64.AppImage',
    '$base-v$version-linux-arm64.tar.gz',
  ];
  return [
    for (final name in names)
      AppUpdateAsset(
        name: name,
        uri: Uri.parse(
          'https://github.com/$updateRepository/releases/download/$tag/$name',
        ),
      ),
  ];
}

/// 检查与下载 GitHub Release 更新。
///
/// 检查主通道为 GitHub API；被匿名限流（HTTP 403，常见于代理/VPN 共享
/// 出口 IP）或网络异常时改用 Release Atom 订阅，用户无需手动干预。
/// 下载在应用内完成并汇报进度：有 sha256 的 GitHub 地址按 [githubProxyPrefixes]
/// 逐源回退后直连兜底，没有摘要或非 GitHub 地址单源直连。
/// 仍由调用方交给系统浏览器或发布页（[AppUpdateAsset.uri]）。
class AppUpdateClient {
  AppUpdateClient({
    http.Client? client,
    Uri? releasesApi,
    this.currentVersion,
    UpdateFileStore? files,
    this.idleTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _releasesApi =
           releasesApi ??
           Uri.parse(
             'https://api.github.com/repos/$updateRepository/releases/latest',
           ),
       files = files ?? const UpdateFileStore();

  final http.Client _client;
  final Uri _releasesApi;

  /// 单个下载源建连后长时间无数据的空闲超时；超时判失败自动换源。
  final Duration idleTimeout;

  /// 当前版本号，例如 `0.4.0`；由调用方从 package_info 获取后写入。
  String? currentVersion;

  /// 文件系统后端，测试可注入自定义实现。
  final UpdateFileStore files;

  /// 检查最新发布：返回 [AppUpdate] 表示有可用更新，null 表示已是最新。
  /// 检查失败抛 [AppUpdateException]。
  Future<AppUpdate?> check() async {
    final current = currentVersion?.trim();
    if (current == null || current.isEmpty) {
      throw const AppUpdateException('无法读取当前版本号。', definitive: true);
    }
    try {
      return await _checkViaApi(current);
    } on AppUpdateException catch (apiError) {
      if (apiError.definitive) rethrow;
      try {
        return await _checkViaAtom(current);
      } on AppUpdateException catch (atomError) {
        throw AppUpdateException(
          '${apiError.message}（备用通道：${atomError.message}）',
        );
      }
    }
  }

  Future<AppUpdate?> _checkViaApi(String current) async {
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
      throw const AppUpdateException('尚未发布任何版本。', definitive: true);
    }
    if (response.statusCode == 403) {
      // 共享出口 IP（如手机代理/VPN）容易触发 GitHub API 匿名限流；
      // 交给 Release Atom 备用通道，无需用户关闭代理重试。
      throw const AppUpdateException(
        'GitHub 接口拒绝访问（HTTP 403），常见于代理或 VPN 出口 IP 被限流。',
      );
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
          final digest = asset['digest'];
          assets.add(
            AppUpdateAsset(
              name: asset['name'] as String,
              uri: Uri.parse(asset['browser_download_url'] as String),
              bytes: asset['size'] is int ? asset['size'] as int : null,
              sha256: digest is String && digest.startsWith('sha256:')
                  ? digest.substring(7)
                  : null,
            ),
          );
        }
      }
    }
    return AppUpdate(
      version: tag,
      notes: body is String ? body : '',
      pageUri: htmlUrl is String ? Uri.parse(htmlUrl) : AppUpdateLinks.releases,
      assets: assets,
    );
  }

  /// 备用检查通道：Release Atom 订阅不受 GitHub API 匿名限流影响。
  Future<AppUpdate?> _checkViaAtom(String current) async {
    http.Response response;
    try {
      response = await _client
          .get(
            AppUpdateLinks.releasesAtom,
            headers: {'user-agent': '$updateRepository-update-check'},
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const AppUpdateException('备用通道超时，请稍后重试。');
    } catch (_) {
      throw const AppUpdateException('无法连接备用通道。');
    }
    if (response.statusCode != 200) {
      throw AppUpdateException('备用通道返回 HTTP ${response.statusCode}。');
    }
    final entry = _firstAtomEntry(utf8.decode(response.bodyBytes));
    if (entry == null) {
      throw const AppUpdateException('备用通道没有可解析的发布记录。');
    }
    if (compareVersions(entry.$1, current) <= 0) return null;
    return AppUpdate(
      version: entry.$1,
      notes: entry.$2,
      pageUri: Uri.parse(
        'https://github.com/$updateRepository/releases/tag/${entry.$1}',
      ),
      assets: _conventionalAssets(entry.$1),
    );
  }

  /// 应用内下载：写入下载目录并返回保存的文件路径。
  ///
  /// 有 sha256 的 GitHub 地址依次经过加速代理，最后直连兜底；没有摘要
  /// 或非 GitHub 地址单源直连。单源失败自动换下一个，摘要一致才会落盘。
  /// 下载被 [isCancelled] 打断时抛 [UpdateDownloadCancelled]；全部源失败
  /// 抛 [AppUpdateException]，残留的临时文件会被清理。
  Future<String> download(
    AppUpdateAsset asset, {
    void Function(int received, int? total)? onProgress,
    void Function(Uri source)? onSource,
    bool Function()? isCancelled,
  }) async {
    final directory = await files.downloadDirectory();
    if (directory == null) {
      throw const AppUpdateException('当前平台不支持应用内下载，请在发布页获取安装包。');
    }
    final target = files.join(directory, asset.name);
    final partial = '$target.part';
    final sources = _assetSources(asset);
    AppUpdateException? lastError;
    try {
      for (final source in sources) {
        if (isCancelled?.call() ?? false) throw const UpdateDownloadCancelled();
        onSource?.call(source);
        try {
          await _downloadFromSource(
            source,
            asset,
            partial,
            onProgress,
            isCancelled,
          );
          await files.move(partial, target);
          return target;
        } on UpdateDownloadCancelled {
          rethrow;
        } on AppUpdateException catch (error) {
          lastError = error;
        }
      }
      throw AppUpdateException('所有下载源均不可用：${lastError?.message ?? '未知错误'}');
    } catch (_) {
      try {
        await files.remove(partial);
      } catch (_) {
        // 清理失败不掩盖原始错误。
      }
      rethrow;
    }
  }

  /// 缺少可信摘要时不能通过第三方代理下载。
  List<Uri> _assetSources(AppUpdateAsset asset) {
    final assetUri = asset.uri;
    final isGitHub =
        assetUri.host == 'github.com' || assetUri.host == 'www.github.com';
    if (!isGitHub || asset.sha256 == null) return [assetUri];
    return [
      for (final prefix in githubProxyPrefixes) Uri.parse('$prefix$assetUri'),
      assetUri,
    ];
  }

  Future<void> _downloadFromSource(
    Uri source,
    AppUpdateAsset asset,
    String partial,
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  ) async {
    final http.StreamedResponse response;
    try {
      response = await _client
          .send(http.Request('GET', source))
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const AppUpdateException('连接下载源超时。');
    } catch (error) {
      throw AppUpdateException('无法连接下载源：$error');
    }
    if (response.statusCode != 200) {
      throw AppUpdateException('下载失败：HTTP ${response.statusCode}。');
    }
    final total = response.contentLength;
    var received = 0;
    var lastNotified = 0;
    var lastNotifiedAt = DateTime.now();
    await files.write(
      partial,
      response.stream
          .handleError((Object error) {
            throw AppUpdateException('下载中断：$error');
          })
          .map((chunk) {
            if (isCancelled?.call() ?? false) {
              throw const UpdateDownloadCancelled();
            }
            received += chunk.length;
            final now = DateTime.now();
            // 进度按 256 KB 或 200ms 粒度汇报：大文件避免逐块重建界面，
            // 慢速网络也能持续刷新速度与剩余时间。
            if (received - lastNotified >= 262144 ||
                (received > lastNotified &&
                    now.difference(lastNotifiedAt).inMilliseconds >= 200)) {
              lastNotified = received;
              lastNotifiedAt = now;
              onProgress?.call(received, total);
            }
            return chunk;
          })
          .timeout(
            idleTimeout,
            onTimeout: (sink) {
              sink.addError(const AppUpdateException('下载中断：长时间未收到数据。'));
              sink.close();
            },
          ),
    );
    if (isCancelled?.call() ?? false) throw const UpdateDownloadCancelled();
    if (total != null && received != total) {
      throw const AppUpdateException('下载不完整，请稍后重试。');
    }
    final expected = asset.sha256;
    if (expected != null) {
      final digest = await files.sha256Of(partial);
      if (digest != expected) {
        // 公开代理属于第三方通道，校验失败视为该源内容不可信，换源重试。
        throw const AppUpdateException('安装包校验失败（sha256 不一致）。');
      }
    }
    onProgress?.call(received, total);
  }

  /// Android：把下载完成的安装包交给系统安装器；首次需「未知来源」授权。
  Future<void> install(String path) => files.installApk(path);

  /// 运行或打开已下载的文件；Windows 用于启动安装器。
  Future<void> openFile(String path) => files.openFile(path);

  /// 在系统文件管理器中显示保存的更新包。
  Future<void> reveal(String path) => files.reveal(path);

  void close() => _client.close();
}
