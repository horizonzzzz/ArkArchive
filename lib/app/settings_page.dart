import 'dart:async';

import '../story_player/data/media_catalog.dart';
import '../story_player/data/playback_settings.dart';
import '../story_player/data/story_repository.dart';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'app_update.dart';
import 'archive_motion.dart';
import 'archive_widgets.dart';

/// 关于页中更新检查的状态机。
enum _UpdatePhase { idle, checking, latest, available, failed }

/// 单个更新资产的下载状态。
class _AssetDownload {
  bool cancelled = false;
  int received = 0;
  int? total;
  String? savedPath;
  String? error;

  /// 当前下载源主机名；换源时变化，用于界面提示。
  String? sourceHost;

  /// 最近 3 秒的（时间戳, 已下载字节）样本，用于计算实时速度。
  final List<MapEntry<int, int>> speedSamples = [];
  double? speedBytesPerSecond;

  bool get active => savedPath == null && error == null;
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.concurrency,
    required this.onConcurrencyChanged,
    required this.isMobile,
    required this.isDesktop,
    required this.caching,
    required this.onOpenDirectory,
    required this.onMoveDirectory,
    required this.directoryBusy,
    required this.onClearCache,
    this.concurrencyBusy = false,
    this.cacheBytes,
    this.cacheLocation,
    this.active = true,
    this.settings = const PlaybackSettings(),
    this.onSettingsChanged,
    this.probe,
    this.mobileDataPrompt = true,
    this.onMobileDataPromptChanged,
    this.onOpenCache,
    this.appVersion,
    this.update,
    this.onOpenLink,
    this.androidAbi,
  });
  final bool concurrencyBusy;
  final bool active;
  final PlaybackSettings settings;
  final ValueChanged<PlaybackSettings>? onSettingsChanged;
  final Future<bool> Function(Uri)? probe;
  final int concurrency;
  final ValueChanged<int> onConcurrencyChanged;
  final bool isMobile;
  final bool isDesktop;
  final bool caching;
  final int? cacheBytes;
  final String? cacheLocation;
  final VoidCallback onOpenDirectory;
  final VoidCallback onMoveDirectory;
  final bool directoryBusy;
  final VoidCallback onClearCache;
  final VoidCallback? onOpenCache;

  /// 移动端非 Wi-Fi 缓存前是否提示确认；关闭后不再弹确认框。
  final bool mobileDataPrompt;
  final ValueChanged<bool>? onMobileDataPromptChanged;

  /// 当前应用版本号，例如 `0.4.0`；由启动页从 package_info 获取后传入。
  final String? appVersion;

  /// 更新检查服务；为 null 时关于页只展示版本与说明，不提供检查入口。
  final AppUpdateClient? update;

  /// 打开外部链接（项目主页、发布页与浏览器下载更新包）。
  final void Function(Uri uri)? onOpenLink;

  /// 设备 Android 架构（如 `arm64-v8a`）；为 null 时关于页自动探测。
  final String? androidAbi;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int? _category;
  late PlaybackSettings _settings = widget.settings;
  bool _checking = false;
  String _indexStatus = '未检测', _assetStatus = '未检测';
  _UpdatePhase _updatePhase = _UpdatePhase.idle;
  AppUpdate? _update;
  String? _updateError;
  final Map<String, _AssetDownload> _downloads = {};

  /// 探测到的 Android 架构；null 表示未知或非 Android。
  String? _androidAbi;

  /// Android 支持应用内下载并拉起系统安装器；iOS 仍交给系统浏览器。
  bool get _androidInApp =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    if (widget.androidAbi == null) unawaited(_detectAndroidAbi());
  }

  /// 网络设置分类在 categories 中的下标。
  static const _networkCategory = 2;

  /// 下钻设置分类；进入网络设置时自动检测一次，无需手动触发。
  void _openCategory(int index) {
    setState(() => _category = index);
    if (index == _networkCategory) _diagnose();
  }

  void _changeSettings(PlaybackSettings value) {
    setState(() => _settings = value);
    widget.onSettingsChanged?.call(value);
  }

  Future<void> _diagnose() async {
    final probe = widget.probe;
    if (probe == null || _checking) return;
    setState(() {
      _checking = true;
      _indexStatus = _assetStatus = '检测中';
    });
    Future<String> check(Uri uri) async {
      try {
        return await probe(uri) ? '连接成功' : '连接失败';
      } catch (_) {
        return '连接失败';
      }
    }

    final results = await Future.wait([
      check(StoryRepository.indexUri),
      check(MediaCatalog.tableUris[1]),
    ]);
    if (!mounted) return;
    setState(() {
      _indexStatus = results[0];
      _assetStatus = results[1];
      _checking = false;
    });
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) _settings = widget.settings;
    if (oldWidget.active && !widget.active) _category = null;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !widget.active || _category == null,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && widget.active && _category != null) {
        setState(() => _category = null);
      }
    },
    child: LayoutBuilder(
      builder: (context, constraints) {
        const categories = [
          (Icons.tune, '基础设置', '主题、音量与播放速度'),
          (Icons.storage_outlined, '缓存设置', '缓存占用、下载并发与本地文件'),
          (Icons.public, '网络设置', '检查剧情与素材连接'),
          (Icons.info_outline, '关于', '版本、更新与开源信息'),
        ];
        final wide = constraints.maxWidth >= 880;
        final content = switch (_category) {
          0 => _playback(),
          1 => _storage(wide),
          2 => _network(),
          3 => _about(),
          _ => ArchivePanel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < categories.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    leading: Icon(
                      categories[i].$1,
                      size: 22,
                      color: AppColors.of(context).subtext,
                    ),
                    title: Text(
                      categories[i].$2,
                      style: const TextStyle(fontSize: 15),
                    ),
                    subtitle: Text(
                      categories[i].$3,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.of(context).subtext,
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => _openCategory(i),
                  ),
                ],
              ],
            ),
          ),
        };
        return ArchivePageTransition(
          transitionKey: _category,
          depth: _category == null ? 0 : 1,
          child: Column(
            children: [
              ArchivePageHeader(
                key: const Key('settings-header'),
                maxWidth: 900,
                title: _category == null ? '系统设置' : categories[_category!].$2,
                leading: _category == null
                    ? null
                    : IconButton(
                        tooltip: '返回设置分类',
                        onPressed: () => setState(() => _category = null),
                        icon: const Icon(Icons.arrow_back, size: 22),
                      ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  key: PageStorageKey('settings-${_category ?? 'root'}'),
                  padding: EdgeInsets.fromLTRB(
                    20,
                    20,
                    20,
                    20 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 860),
                      child: content,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  Widget _section(List<Widget> children) => ArchivePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget _playback() => _section([
    SwitchListTile(
      key: const ValueKey('setting-light-theme'),
      contentPadding: EdgeInsets.zero,
      title: const Text('明亮色主题'),
      subtitle: const Text('关闭时使用方舟风格暗色主题'),
      value: _settings.lightTheme,
      onChanged: (value) =>
          _changeSettings(_settings.copyWith(lightTheme: value)),
    ),
    const Divider(height: 20),
    _slider(
      '主音量',
      _settings.master * 100,
      0,
      100,
      '${(_settings.master * 100).round()}%',
      (v) => _changeSettings(_settings.copyWith(master: v / 100)),
      divisions: 100,
    ),
    _slider(
      '背景音乐 BGM',
      _settings.bgm * 100,
      0,
      100,
      '${(_settings.bgm * 100).round()}%',
      (v) => _changeSettings(_settings.copyWith(bgm: v / 100)),
      divisions: 100,
    ),
    _slider(
      '音效与环境 SFX',
      _settings.sfx * 100,
      0,
      100,
      '${(_settings.sfx * 100).round()}%',
      (v) => _changeSettings(_settings.copyWith(sfx: v / 100)),
      divisions: 100,
    ),
    const Divider(height: 20),
    _slider(
      '自动播放等待',
      _settings.autoDelay,
      1,
      5,
      '${_settings.autoDelay.round()} 秒',
      (v) => _changeSettings(_settings.copyWith(autoDelay: v)),
      divisions: 4,
    ),
    _slider(
      '逐字出字间隔',
      _settings.typingMs,
      10,
      80,
      '${_settings.typingMs.round()} ms',
      (v) => _changeSettings(_settings.copyWith(typingMs: v)),
      divisions: 14,
    ),
  ]);

  Widget _storage(bool wide) => _section([
    if (widget.onOpenCache != null) ...[
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.download_outlined),
        title: const Text('离线与缓存'),
        trailing: const Icon(Icons.chevron_right),
        onTap: widget.onOpenCache,
      ),
      const Divider(height: 20),
    ],
    if (widget.isMobile) ...[
      SwitchListTile(
        key: const ValueKey('setting-移动数据缓存提示'),
        contentPadding: EdgeInsets.zero,
        title: const Text('移动数据缓存提示', style: TextStyle(fontSize: 13)),
        subtitle: Text(
          '关闭后，使用移动数据缓存前不再弹窗确认。',
          style: TextStyle(fontSize: 12, color: AppColors.of(context).subtext),
        ),
        value: widget.mobileDataPrompt,
        onChanged: widget.onMobileDataPromptChanged,
      ),
      const Divider(height: 20),
    ],
    Text(
      widget.cacheBytes == null
          ? '缓存占用：无法读取'
          : '缓存占用：${(widget.cacheBytes! / 1048576).toStringAsFixed(1)} MB',
      style: TextStyle(fontSize: 12, color: AppColors.of(context).muted),
    ),
    if (widget.isDesktop) ...[
      const Divider(height: 20),
      Text(
        '本地媒体缓存目录',
        style: TextStyle(fontSize: 13, color: AppColors.of(context).text),
      ),
      const SizedBox(height: 8),
      SelectableText(
        widget.cacheLocation ?? '无法读取',
        style: TextStyle(fontSize: 12, color: AppColors.of(context).muted),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: widget.directoryBusy ? null : widget.onOpenDirectory,
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('打开目录'),
          ),
          OutlinedButton.icon(
            onPressed: widget.directoryBusy ? null : widget.onMoveDirectory,
            icon: const Icon(Icons.drive_file_move_outline, size: 16),
            label: const Text('更改目录'),
          ),
        ],
      ),
      if (defaultTargetPlatform == TargetPlatform.windows) ...[
        const SizedBox(height: 6),
        Text(
          '路径不能包含中文：Windows 上中文路径会导致音频无法播放。',
          style: TextStyle(fontSize: 12, color: AppColors.of(context).yellow),
        ),
      ],
    ],
    const SizedBox(height: 8),
    _slider(
      '并发下载数',
      widget.concurrency.toDouble(),
      1,
      8,
      '${widget.concurrency.toDouble().round()}',
      widget.concurrencyBusy
          ? null
          : (value) => widget.onConcurrencyChanged(value.round()),
      divisions: 7,
    ),
    const SizedBox(height: 14),
    OutlinedButton.icon(
      onPressed: widget.directoryBusy || widget.caching
          ? null
          : widget.onClearCache,
      icon: Icon(
        Icons.delete_outline,
        size: 17,
        color: AppColors.of(context).danger,
      ),
      label: Text(
        '清空素材缓存',
        style: TextStyle(color: AppColors.of(context).danger),
      ),
    ),
  ]);

  Widget _network() => _section([
    _statusRow('剧情索引', 'torappu.prts.wiki', _indexStatus),
    const SizedBox(height: 14),
    _statusRow('素材分发节点', 'torappu.prts.wiki/assets', _assetStatus),
    const SizedBox(height: 14),
    OutlinedButton.icon(
      onPressed: _checking || widget.probe == null ? null : _diagnose,
      icon: const Icon(Icons.network_check, size: 18),
      label: const Text('重新检测'),
    ),
  ]);

  // ------------------------------------------------------------
  // 关于：应用信息、检查与下载更新、链接与声明。
  // ------------------------------------------------------------

  Future<void> _checkUpdate() async {
    final update = widget.update;
    if (update == null || _updatePhase == _UpdatePhase.checking) return;
    setState(() => _updatePhase = _UpdatePhase.checking);
    try {
      final result = await update.check();
      if (!mounted) return;
      setState(() {
        _update = result;
        _updateError = null;
        _updatePhase = result == null
            ? _UpdatePhase.latest
            : _UpdatePhase.available;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _updateError = error is AppUpdateException ? error.message : '$error';
        _updatePhase = _UpdatePhase.failed;
      });
    }
  }

  void _startAssetDownload(AppUpdateAsset asset) {
    final update = widget.update;
    if (update == null) return;
    final existing = _downloads[asset.name];
    if (existing != null && existing.active) return;
    final download = _AssetDownload();
    setState(() => _downloads[asset.name] = download);
    update
        .download(
          asset,
          onProgress: (received, total) {
            if (mounted) {
              setState(() => _recordProgress(download, received, total));
            }
          },
          onSource: (source) {
            if (mounted) {
              setState(() {
                download
                  ..sourceHost = source.host
                  ..received = 0
                  ..total = null
                  ..speedBytesPerSecond = null
                  ..speedSamples.clear();
              });
            }
          },
          isCancelled: () => download.cancelled,
        )
        .then((path) {
          if (!mounted) return;
          setState(() => download.savedPath = path);
          if (_androidInApp) {
            // 下载完成即拉起系统安装器；未授权或失败时保留手动「安装」按钮。
            update.install(path).ignore();
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_androidInApp ? '安装包已下载完成。' : '更新已保存到 $path'),
              action: SnackBarAction(
                label: _androidInApp ? '安装' : '打开所在文件夹',
                onPressed: () => _androidInApp
                    ? _installUpdateFile(path)
                    : _revealUpdateFile(path),
              ),
            ),
          );
        })
        .catchError((Object error) {
          if (mounted) {
            setState(() {
              download.error = error is UpdateDownloadCancelled
                  ? '已取消下载。'
                  : '$error';
            });
          }
        });
  }

  void _cancelAssetDownload(_AssetDownload download) {
    setState(() => download.cancelled = true);
  }

  /// 记录进度样本并按 3 秒滑动窗口计算实时速度。
  void _recordProgress(_AssetDownload download, int received, int? total) {
    if (received < download.received) {
      // 换源后从头下载，重置速度统计。
      download.speedSamples.clear();
      download.speedBytesPerSecond = null;
    }
    download.received = received;
    download.total = total;
    final now = DateTime.now().millisecondsSinceEpoch;
    download.speedSamples.add(MapEntry(now, received));
    while (download.speedSamples.length > 1 &&
        now - download.speedSamples.first.key >= 3000) {
      download.speedSamples.removeAt(0);
    }
    if (download.speedSamples.length > 1) {
      final first = download.speedSamples.first;
      final last = download.speedSamples.last;
      final seconds = (last.key - first.key) / 1000;
      if (seconds > 0) {
        download.speedBytesPerSecond = (last.value - first.value) / seconds;
      }
    }
  }

  Future<void> _installUpdateFile(String path) async {
    try {
      await widget.update?.install(path);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('无法启动安装：$error')));
    }
  }

  Future<void> _runInstaller(String path) async {
    try {
      await widget.update?.openFile(path);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('无法运行安装程序：$error')));
    }
  }

  Future<void> _revealUpdateFile(String path) async {
    try {
      await widget.update?.reveal(path);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法打开所在文件夹：$error')));
      }
    }
  }

  Widget _about() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ArchivePanel(
        child: Row(
          children: [
            Image.asset(
              'assets/images/app_icon.png',
              width: 46,
              height: 46,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '方舟档案室',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '明日方舟剧情离线播放器',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).subtext,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text(
                        '版本',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.of(context).muted,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        key: const ValueKey('about-version'),
                        widget.appVersion == null
                            ? '无法读取'
                            : 'v${widget.appVersion}',
                        style: TextStyle(
                          fontFamily: AppTypography.bender,
                          fontFamilyFallback: [AppTypography.sans],
                          color: AppColors.of(context).terminalWhite,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: .6,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _aboutUpdate(),
      const SizedBox(height: 12),
      _aboutLinks(),
      const SizedBox(height: 12),
      _aboutNotice(),
    ],
  );

  Widget _aboutUpdate() => ArchivePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('应用更新', style: TextStyle(fontSize: 15))),
            OutlinedButton.icon(
              key: const ValueKey('about-check-update'),
              onPressed:
                  _updatePhase == _UpdatePhase.checking || widget.update == null
                  ? null
                  : _checkUpdate,
              icon: _updatePhase == _UpdatePhase.checking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.update_outlined, size: 18),
              label: Text(
                _updatePhase == _UpdatePhase.checking ? '正在检查…' : '检查更新',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        switch (_updatePhase) {
          _UpdatePhase.idle => Text(
            widget.update == null
                ? '此构建未接入更新检查。'
                : '检查 GitHub 上的最新发布版本，应用内下载并显示进度、速度与剩余时间。',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.of(context).subtext,
            ),
          ),
          _UpdatePhase.checking => Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text(
                '正在检查更新…',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.of(context).subtext,
                ),
              ),
            ],
          ),
          _UpdatePhase.latest => Row(
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 16,
                color: AppColors.of(context).green,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '已是最新版本。',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.of(context).secondary,
                  ),
                ),
              ),
            ],
          ),
          _UpdatePhase.failed => Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 16,
                color: AppColors.of(context).danger,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '检查更新失败：$_updateError',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.of(context).danger,
                  ),
                ),
              ),
            ],
          ),
          _UpdatePhase.available => _updateAvailable(),
        },
      ],
    ),
  );

  Widget _updateAvailable() {
    final update = _update!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.new_releases_outlined,
              size: 16,
              color: AppColors.of(context).yellow,
            ),
            const SizedBox(width: 8),
            Text(
              '发现新版本',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.of(context).yellow,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              update.version,
              style: TextStyle(
                fontFamily: AppTypography.bender,
                fontFamilyFallback: [AppTypography.sans],
                color: AppColors.of(context).terminalWhite,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: .6,
              ),
            ),
          ],
        ),
        if (update.notes.trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          SelectableText(
            update.notes.trim(),
            style: TextStyle(
              fontSize: 12,
              color: AppColors.of(context).secondary,
              height: 1.7,
            ),
          ),
        ],
        const SizedBox(height: 14),
        ..._updateDownloadArea(update),
      ],
    );
  }

  /// 资产文件名中的平台标识；Web 返回空串展示全部，无构建产物的平台返回 null。
  String? _assetPlatformToken() {
    if (kIsWeb) return '';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => '-android-',
      TargetPlatform.windows => '-windows-',
      TargetPlatform.linux => '-linux-',
      _ => null,
    };
  }

  /// 更新下载区域：Web 展示全部资产，Windows 同时展示安装器和便携包。
  List<Widget> _updateDownloadArea(AppUpdate update) {
    if (kIsWeb) {
      return [
        for (final asset in update.assets) ...[
          _updateAssetRow(asset),
          const SizedBox(height: 8),
        ],
      ];
    }
    final asset = _preferredUpdateAsset(update);
    if (asset == null) {
      return [
        Text(
          '当前平台没有可自动匹配的安装包，请在发布页面查看全部文件。',
          style: TextStyle(fontSize: 12, color: AppColors.of(context).subtext),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey('about-update-page'),
          onPressed: widget.onOpenLink == null
              ? null
              : () => widget.onOpenLink!(update.pageUri),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('打开发布页面'),
        ),
      ];
    }
    return [
      if (defaultTargetPlatform == TargetPlatform.android) ...[
        Text(
          '已自动匹配设备架构，直接下载安装即可。',
          style: TextStyle(fontSize: 11, color: AppColors.of(context).muted),
        ),
        const SizedBox(height: 8),
      ],
      _updateAssetRow(asset),
      if (defaultTargetPlatform == TargetPlatform.windows)
        for (final portable in update.assets.where(
          (candidate) =>
              candidate.name.contains('-windows-') &&
              candidate.name.endsWith('.zip') &&
              candidate.name != asset.name,
        )) ...[const SizedBox(height: 8), _updateAssetRow(portable)],
    ];
  }

  /// 从发布资产中挑出本设备应下载的那一个安装包。
  ///
  /// Android 优先精确匹配设备 ABI，其次 universal，最后唯一候选；
  /// Windows 同时发布便携 ZIP 与安装器时优先选中安装器，界面另展示 ZIP；
  /// 其他平台只有唯一候选时给出下载入口，否则交回发布页面。
  AppUpdateAsset? _preferredUpdateAsset(AppUpdate update) {
    final token = _assetPlatformToken();
    if (token == null) return null;
    final matching = update.assets
        .where((asset) => asset.name.contains(token))
        .toList();
    if (matching.isEmpty) return null;
    if (token == '-android-') {
      final abi = widget.androidAbi ?? _androidAbi;
      if (abi != null) {
        final exact = matching
            .where((asset) => asset.name.contains('-$abi.'))
            .toList();
        if (exact.isNotEmpty) return exact.first;
      }
      final universal = matching
          .where((asset) => asset.name.contains('universal'))
          .toList();
      if (universal.isNotEmpty) return universal.first;
      if (matching.length == 1) return matching.single;
      return null;
    }
    if (token == '-windows-') {
      final installers = matching
          .where((asset) => asset.name.endsWith('-setup.exe'))
          .toList();
      if (installers.isNotEmpty) return installers.first;
    }
    return matching.length == 1 ? matching.single : null;
  }

  Future<void> _detectAndroidAbi() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final abi = await detectAndroidAbi();
    if (mounted) setState(() => _androidAbi = abi);
  }

  Widget _updateAssetRow(AppUpdateAsset asset) {
    final download = _downloads[asset.name];
    final active = download != null && download.active;
    final saved = download?.savedPath;
    final error = download?.error;
    // Android 与桌面端支持应用内下载，iOS/Web 交给系统浏览器。
    final inApp = _androidInApp || widget.isDesktop;
    final total = download?.total;
    final progress = active && total != null && total > 0
        ? download.received / total
        : null;
    return Container(
      key: ValueKey('about-asset-${asset.name}'),
      color: AppColors.of(context).surface,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(asset.name, style: const TextStyle(fontSize: 12)),
              ),
              if (asset.bytes != null) ...[
                const SizedBox(width: 10),
                Text(
                  '${(asset.bytes! / 1048576).toStringAsFixed(1)} MB',
                  style: TextStyle(
                    fontFamily: AppTypography.bender,
                    fontFamilyFallback: [AppTypography.sans],
                    fontSize: 11,
                    color: AppColors.of(context).muted,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (saved != null)
            Row(
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 15,
                  color: AppColors.of(context).green,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    _androidInApp ? '已下载安装包' : '已保存到下载目录',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).secondary,
                    ),
                  ),
                ),
                if (_androidInApp)
                  TextButton(
                    key: ValueKey('about-install-${asset.name}'),
                    onPressed: () => _installUpdateFile(saved),
                    child: const Text('安装'),
                  )
                else if (!kIsWeb &&
                    defaultTargetPlatform == TargetPlatform.windows &&
                    asset.name.endsWith('-setup.exe'))
                  TextButton(
                    key: ValueKey('about-run-installer-${asset.name}'),
                    onPressed: () => _runInstaller(saved),
                    child: const Text('运行安装程序'),
                  ),
                if (!_androidInApp)
                  TextButton(
                    onPressed: () => _revealUpdateFile(saved),
                    child: const Text('打开所在文件夹'),
                  ),
              ],
            )
          else if (error != null)
            Row(
              children: [
                Icon(
                  Icons.error_outline,
                  size: 15,
                  color: AppColors.of(context).danger,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    error,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).danger,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: inApp ? () => _startAssetDownload(asset) : null,
                  child: const Text('重新下载'),
                ),
              ],
            )
          else if (active)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _downloadProgressLabel(download),
                        style: TextStyle(
                          fontFamily: AppTypography.bender,
                          fontFamilyFallback: [AppTypography.sans],
                          fontSize: 11,
                          color: AppColors.of(context).subtext,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _cancelAssetDownload(download),
                      child: const Text('取消'),
                    ),
                  ],
                ),
                if (download.sourceHost != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '下载源 ${download.sourceHost} · 失败自动换源',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.of(context).muted,
                    ),
                  ),
                ],
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: Text(
                    inApp
                        ? (_androidInApp ? '下载安装包到本机' : '保存到系统下载目录')
                        : '通过系统浏览器下载',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.of(context).muted,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  key: ValueKey('about-download-${asset.name}'),
                  onPressed: inApp
                      ? () => _startAssetDownload(asset)
                      : () => widget.onOpenLink?.call(asset.uri),
                  icon: Icon(
                    inApp ? Icons.download_outlined : Icons.open_in_new,
                    size: 16,
                  ),
                  label: const Text('下载'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) => bytes >= 1048576
      ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).round()} KB';

  /// 进度文案：字节、百分比、实时速度与预计剩余时间。
  String _downloadProgressLabel(_AssetDownload download) {
    final total = download.total;
    final buffer = StringBuffer(
      total == null || total <= 0
          ? '${_formatBytes(download.received)} / 未知'
          : '${_formatBytes(download.received)} / ${_formatBytes(total)}'
                ' · ${(download.received * 100 / total).round()}%',
    );
    final speed = download.speedBytesPerSecond;
    if (speed != null && speed > 0) {
      buffer.write(' · ${_formatSpeed(speed)}');
      if (total != null && total > download.received) {
        buffer.write(
          ' · 剩余 ${_formatDuration((total - download.received) / speed)}',
        );
      }
    }
    return buffer.toString();
  }

  String _formatSpeed(double bytesPerSecond) => bytesPerSecond >= 1048576
      ? '${(bytesPerSecond / 1048576).toStringAsFixed(1)} MB/s'
      : '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';

  String _formatDuration(double seconds) {
    if (!seconds.isFinite || seconds < 0) return '—';
    final total = seconds.round();
    String two(int value) => value.toString().padLeft(2, '0');
    if (total >= 3600) {
      return '${total ~/ 3600}:${two((total % 3600) ~/ 60)}:${two(total % 60)}';
    }
    return '${two(total ~/ 60)}:${two(total % 60)}';
  }

  Widget _aboutLinks() => ArchivePanel(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _aboutLinkTile(
          Icons.home_work_outlined,
          '项目主页',
          'GitHub 仓库与源码',
          AppUpdateLinks.project,
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        _aboutLinkTile(
          Icons.bug_report_outlined,
          '问题反馈',
          '在 GitHub Issues 提交问题',
          AppUpdateLinks.issues,
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        _aboutLinkTile(
          Icons.history_outlined,
          '更新日志',
          '查看全部发布说明',
          AppUpdateLinks.releases,
        ),
      ],
    ),
  );

  Widget _aboutLinkTile(
    IconData icon,
    String title,
    String subtitle,
    Uri uri,
  ) => ListTile(
    key: ValueKey('about-link-$title'),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    leading: Icon(icon, size: 22, color: AppColors.of(context).subtext),
    title: Text(title, style: const TextStyle(fontSize: 15)),
    subtitle: Text(
      subtitle,
      style: TextStyle(fontSize: 12, color: AppColors.of(context).subtext),
    ),
    trailing: Icon(
      Icons.open_in_new,
      size: 18,
      color: AppColors.of(context).muted,
    ),
    onTap: widget.onOpenLink == null ? null : () => widget.onOpenLink!(uri),
  );

  Widget _aboutNotice() => ArchivePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('数据来源与声明', style: TextStyle(fontSize: 15)),
        const SizedBox(height: 10),
        Text(
          '剧情脚本、目录索引与多媒体素材来自 PRTS Wiki（torappu.prts.wiki）'
          '与 Kengxxiao/ArknightsGameData 等社区解包项目，'
          '相关内容版权归鹰角网络所有。',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.of(context).secondary,
            height: 1.8,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '本应用为社区非官方作品，与鹰角网络无关联，仅用于离线浏览剧情演出，'
          '请勿用于任何商业用途。',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.of(context).secondary,
            height: 1.8,
          ),
        ),
      ],
    ),
  );

  Widget _statusRow(String title, String description, String status) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 5),
            Text(
              description,
              style: TextStyle(
                fontSize: 10,
                color: AppColors.of(context).muted,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 8),
      ArchiveTag(status),
    ],
  );

  Widget _slider(
    String title,
    double value,
    double min,
    double max,
    String label,
    ValueChanged<double>? onChanged, {
    required int divisions,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: 13))),
            Text(
              label,
              style: TextStyle(
                fontFamily: AppTypography.bender,
                fontFamilyFallback: [AppTypography.sans],
                color: AppColors.of(context).terminalWhite,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Semantics(
          label: title,
          child: Slider(
            key: ValueKey('setting-$title'),
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
          ),
        ),
      ],
    ),
  );
}
