import '../story_player/data/media_catalog.dart';
import '../story_player/data/playback_settings.dart';
import '../story_player/data/story_repository.dart';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'archive_motion.dart';
import 'archive_widgets.dart';

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

  /// 移动端非 Wi-Fi 缓存前是否提示确认；关闭后不再弹确认框。
  final bool mobileDataPrompt;
  final ValueChanged<bool>? onMobileDataPromptChanged;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int? _category;
  late PlaybackSettings _settings = widget.settings;
  bool _checking = false;
  String _indexStatus = '未检测', _assetStatus = '未检测';

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
        ];
        final wide = constraints.maxWidth >= 880;
        final content = switch (_category) {
          0 => _audio(),
          1 => _playback(),
          2 => _storage(wide),
          3 => _network(),
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
                    onTap: () => setState(() => _category = i),
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
      label: const Text('连接诊断'),
    ),
  ]);

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
