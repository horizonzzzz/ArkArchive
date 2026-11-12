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

  @override
  void initState() {
    super.initState();
    if (widget.androidAbi == null) unawaited(_detectAndroidAbi());
  }

  /// 网络与节点分类在 categories 中的下标。
  static const _networkCategory = 3;

  /// 下钻设置分类；进入网络与节点时自动检测一次，无需手动触发。
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
          (Icons.graphic_eq, '音频通道', '主音量、音乐与音效'),
          (Icons.slow_motion_video, '演出偏好', '自动播放与文字显示速度'),
          (Icons.storage_outlined, '存储与缓存', '缓存占用、下载并发与本地文件'),
          (Icons.public, '网络与节点', '检查剧情与素材连接'),
          (Icons.info_outline, '关于', '版本、更新与开源信息'),
        ];
        final wide = constraints.maxWidth >= 880;
        final content = switch (_category) {
          0 => _audio(),
          1 => _playback(),
          2 => _storage(wide),
          3 => _network(),
          4 => _about(),
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
                      color: AppColors.subtext,
                    ),
                    title: Text(
                      categories[i].$2,
                      style: const TextStyle(fontSize: 15),
                    ),
                    subtitle: Text(
                      categories[i].$3,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.subtext,
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

  Widget _audio() => _section([
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
  ]);

  Widget _playback() => _section([
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
        subtitle: const Text(
          '关闭后，使用移动数据缓存前不再弹窗确认。',
          style: TextStyle(fontSize: 12, color: AppColors.subtext),
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
      style: const TextStyle(fontSize: 12, color: AppColors.muted),
    ),
    if (widget.isDesktop) ...[
      const Divider(height: 20),
      const Text(
        '本地媒体缓存目录',
        style: TextStyle(fontSize: 13, color: AppColors.text),
      ),
      const SizedBox(height: 8),
      SelectableText(
        widget.cacheLocation ?? '无法读取',
        style: const TextStyle(fontSize: 12, color: AppColors.muted),
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
        const Text(
          '路径不能包含中文：Windows 上中文路径会导致音频无法播放。',
          style: TextStyle(fontSize: 12, color: AppColors.yellow),
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
      icon: const Icon(Icons.delete_outline, size: 17, color: AppColors.danger),
      label: const Text('清空素材缓存', style: TextStyle(color: AppColors.danger)),
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
        _updatePhase =
            result == null ? _UpdatePhase.latest : _UpdatePhase.available;
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
              setState(() {
                download.received = received;
                download.total = total;
              });
            }
          },
          isCancelled: () => download.cancelled,
        )
        .then((path) {
          if (!mounted) return;
          setState(() => download.savedPath = path);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('更新已保存到 $path'),
              action: SnackBarAction(
                label: '打开所在文件夹',
                onPressed: () => _revealUpdateFile(path),
              ),
            ),
          );
        })
        .catchError((Object error) {
          if (mounted) {
            setState(() {
              download.error =
                  error is UpdateDownloadCancelled ? '已取消下载。' : '$error';
            });
          }
        });
  }

  void _cancelAssetDownload(_AssetDownload download) {
    setState(() => download.cancelled = true);
  }

  Future<void> _revealUpdateFile(String path) async {
    try {
      await widget.update?.reveal(path);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法打开所在文件夹：$error')));
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
                  const Text(
                    '明日方舟剧情离线播放器',
                    style: TextStyle(fontSize: 12, color: AppColors.subtext),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text(
                        '版本',
                        style: TextStyle(fontSize: 12, color: AppColors.muted),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        key: const ValueKey('about-version'),
                        widget.appVersion == null
                            ? '无法读取'
                            : 'v${widget.appVersion}',
                        style: const TextStyle(
                          fontFamily: AppTypography.bender,
                          fontFamilyFallback: [AppTypography.sans],
                          color: AppColors.terminalWhite,
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
            const Expanded(
              child: Text('应用更新', style: TextStyle(fontSize: 15)),
            ),
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
                : '检查 GitHub 上的最新发布版本，桌面端可在应用内下载安装包。',
            style: const TextStyle(fontSize: 12, color: AppColors.subtext),
          ),
          _UpdatePhase.checking => const Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text(
                '正在检查更新…',
                style: TextStyle(fontSize: 12, color: AppColors.subtext),
              ),
            ],
          ),
          _UpdatePhase.latest => const Row(
            children: [
              Icon(Icons.check_circle_outline, size: 16, color: AppColors.green),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '已是最新版本。',
                  style: TextStyle(fontSize: 12, color: AppColors.secondary),
                ),
              ),
            ],
          ),
          _UpdatePhase.failed => Row(
            children: [
              const Icon(Icons.error_outline, size: 16, color: AppColors.danger),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '检查更新失败：$_updateError',
                  style: const TextStyle(fontSize: 12, color: AppColors.danger),
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
            const Icon(
              Icons.new_releases_outlined,
              size: 16,
              color: AppColors.yellow,
            ),
            const SizedBox(width: 8),
            const Text(
              '发现新版本',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.yellow,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              update.version,
              style: const TextStyle(
                fontFamily: AppTypography.bender,
                fontFamilyFallback: [AppTypography.sans],
                color: AppColors.terminalWhite,
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
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.secondary,
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

  /// 更新下载区域：Web 展示全部资产，其余平台只给本设备应下载的那一个安装包。
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
        const Text(
          '当前平台没有可自动匹配的安装包，请在发布页面查看全部文件。',
          style: TextStyle(fontSize: 12, color: AppColors.subtext),
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
        const Text(
          '已自动匹配设备架构，直接下载安装即可。',
          style: TextStyle(fontSize: 11, color: AppColors.muted),
        ),
        const SizedBox(height: 8),
      ],
      _updateAssetRow(asset),
    ];
  }

  /// 从发布资产中挑出本设备应下载的那一个安装包。
  ///
  /// Android 优先精确匹配设备 ABI，其次 universal，最后唯一候选；
  /// 其他平台只有唯一候选时给出下载入口，否则交回发布页面。
  AppUpdateAsset? _preferredUpdateAsset(AppUpdate update) {
    final token = _assetPlatformToken();
    if (token == null) return null;
    final matching = update.assets
        .where((asset) => asset.name.contains(token))
        .toList();
    if (matching.isEmpty) return null;
    if (token != '-android-') {
      return matching.length == 1 ? matching.single : null;
    }
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
    // 桌面端支持应用内下载，其他平台交给系统浏览器。
    final inApp = widget.isDesktop;
    final total = download?.total;
    final progress = active && total != null && total > 0
        ? download.received / total
        : null;
    return Container(
      key: ValueKey('about-asset-${asset.name}'),
      color: AppColors.surface,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  asset.name,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              if (asset.bytes != null) ...[
                const SizedBox(width: 10),
                Text(
                  '${(asset.bytes! / 1048576).toStringAsFixed(1)} MB',
                  style: const TextStyle(
                    fontFamily: AppTypography.bender,
                    fontFamilyFallback: [AppTypography.sans],
                    fontSize: 11,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (saved != null)
            Row(
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  size: 15,
                  color: AppColors.green,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '已保存到下载目录',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.secondary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => _revealUpdateFile(saved),
                  child: const Text('打开所在文件夹'),
                ),
              ],
            )
          else if (error != null)
            Row(
              children: [
                const Icon(Icons.error_outline, size: 15, color: AppColors.danger),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    error,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.danger,
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
                        total == null
                            ? '${_formatBytes(download.received)} / 未知'
                            : '${_formatBytes(download.received)} / ${_formatBytes(total)} · ${(download.received * 100 / total).round()}%',
                        style: const TextStyle(
                          fontFamily: AppTypography.bender,
                          fontFamilyFallback: [AppTypography.sans],
                          fontSize: 11,
                          color: AppColors.subtext,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _cancelAssetDownload(download),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: Text(
                    inApp ? '保存到系统下载目录' : '通过系统浏览器下载',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.muted,
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
    leading: Icon(icon, size: 22, color: AppColors.subtext),
    title: Text(title, style: const TextStyle(fontSize: 15)),
    subtitle: Text(
      subtitle,
      style: const TextStyle(fontSize: 12, color: AppColors.subtext),
    ),
    trailing: const Icon(Icons.open_in_new, size: 18, color: AppColors.muted),
    onTap: widget.onOpenLink == null ? null : () => widget.onOpenLink!(uri),
  );

  Widget _aboutNotice() => ArchivePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('数据来源与声明', style: TextStyle(fontSize: 15)),
        const SizedBox(height: 10),
        const Text(
          '剧情脚本、目录索引与多媒体素材来自 PRTS Wiki（torappu.prts.wiki）'
          '与 Kengxxiao/ArknightsGameData 等社区解包项目，'
          '相关内容版权归鹰角网络所有。',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.secondary,
            height: 1.8,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '本应用为社区非官方作品，与鹰角网络无关联，仅用于离线浏览剧情演出，'
          '请勿用于任何商业用途。',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.secondary,
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
              style: const TextStyle(fontSize: 10, color: AppColors.muted),
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
              style: const TextStyle(
                fontFamily: AppTypography.bender,
                fontFamilyFallback: [AppTypography.sans],
                color: AppColors.terminalWhite,
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
