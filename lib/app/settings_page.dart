import 'package:flutter/material.dart';

import 'app_theme.dart';
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
  });
  final bool concurrencyBusy;
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
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _volumes = <String, double>{
    '主音量': 80,
    '背景音乐 BGM': 75,
    '音效与环境 SFX': 85,
    '语音 Voice（预留）': 80,
  };
  bool _offline = false;
  bool _skipConfirmation = true;
  bool _landscape = true;
  double _autoDelay = 2;
  double _typewriter = 40;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 880;
      final sections = [_audio(), _playback(), _storage(wide), _network()];
      return SingleChildScrollView(
        key: const PageStorageKey('settings-scroll'),
        padding: EdgeInsets.all(constraints.maxWidth < 600 ? 16 : 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1240),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ArchiveHeading('系统设置'),
                const SizedBox(height: 20),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            sections[0],
                            const SizedBox(height: 16),
                            sections[2],
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          children: [
                            sections[1],
                            const SizedBox(height: 16),
                            sections[3],
                          ],
                        ),
                      ),
                    ],
                  )
                else ...[
                  for (final section in sections) ...[
                    section,
                    const SizedBox(height: 14),
                  ],
                ],
                const SizedBox(height: 24),
                const Text(
                  '明日方舟剧情播放器 · PRTS TERMINAL\n数据来源 PRTS 维基与公开网络解构。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    height: 1.7,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _section(
    String title,
    String subtitle,
    IconData icon,
    List<Widget> children,
  ) => ArchivePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, color: AppColors.terminalWhite, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.text,
                ),
              ),
            ),
            Text(
              subtitle,
              style: const TextStyle(
                color: AppColors.muted,
                letterSpacing: 1.5,
                fontSize: 9,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 12),
        ...children,
      ],
    ),
  );

  Widget _audio() => _section('音频通道', '01 // AUDIO', Icons.graphic_eq, [
    for (final entry in _volumes.entries)
      _slider(
        entry.key,
        entry.value,
        0,
        100,
        '${entry.value.round()}%',
        (value) => setState(() => _volumes[entry.key] = value),
        divisions: 100,
      ),
  ]);

  Widget _playback() =>
      _section('演出偏好', '02 // PLAYBACK', Icons.slow_motion_video, [
        _toggle(
          '横屏沉浸播放',
          '启用横屏全屏舞台渲染',
          _landscape,
          (value) => setState(() => _landscape = value),
        ),
        _slider(
          '自动播放等待',
          _autoDelay,
          1,
          5,
          '${_autoDelay.round()} 秒',
          (value) => setState(() => _autoDelay = value),
          divisions: 4,
        ),
        _slider(
          '逐字出字间隔',
          _typewriter,
          10,
          80,
          '${_typewriter.round()} ms',
          (value) => setState(() => _typewriter = value),
          divisions: 14,
        ),
        _toggle(
          '跳过对白前确认',
          '跳过整段对白前弹出拦截确认',
          _skipConfirmation,
          (value) => setState(() => _skipConfirmation = value),
        ),
        const Divider(height: 20),
        const Text(
          '对白样式基准',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.subtext,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: const BoxDecoration(
            color: AppColors.canvas,
            border: Border(
              left: BorderSide(color: AppColors.indicator, width: 2),
            ),
          ),
          child: const Text(
            '「罗德岛各部门注意，准备进入预定作战区域。」',
            style: TextStyle(fontSize: 13, height: 1.6, color: AppColors.text),
          ),
        ),
      ]);

  Widget _storage(
    bool wide,
  ) => _section('存储与缓存', '03 // STORAGE', Icons.storage_outlined, [
    if (widget.isMobile) ...[
      const Text(
        '使用移动数据缓存前会提示确认。',
        style: TextStyle(fontSize: 12, color: AppColors.muted),
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

  Widget _network() => _section('网络与节点', '04 // NETWORK', Icons.public, [
    _toggle(
      '强制离线模式',
      '预览功能，尚未限制网络请求',
      _offline,
      (value) => setState(() => _offline = value),
    ),
    const Divider(height: 20),
    _statusRow('剧情索引', 'torappu.prts.wiki', '未检测'),
    const SizedBox(height: 14),
    _statusRow('素材分发节点', 'PRTS STATIC CDN', '未检测'),
    const SizedBox(height: 14),
    OutlinedButton.icon(
      onPressed: () => showPreviewMessage(context, '连接诊断'),
      icon: const Icon(Icons.network_check, size: 18),
      label: const Text('连接诊断'),
    ),
    const Divider(height: 20),
    _statusRow('客户端版本', 'RHODES-OS v4.1', '1.0.0'),
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

  Widget _toggle(
    String title,
    String description,
    bool value,
    ValueChanged<bool>? onChanged,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 5),
              Text(
                description,
                style: const TextStyle(fontSize: 11, color: AppColors.muted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Semantics(
          label: '$title（预览）',
          child: Switch(value: value, onChanged: onChanged),
        ),
      ],
    ),
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
                color: AppColors.terminalWhite,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Semantics(
          label: title == '并发下载数' ? title : '$title（预览）',
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
