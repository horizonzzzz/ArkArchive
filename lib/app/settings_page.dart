import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'archive_widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _volumes = <String, double>{'主音量': 80, '背景音乐 BGM': 75, '音效与环境 SFX': 85, '语音 Voice（预留）': 80};
  bool _wifiOnly = true;
  bool _offline = false;
  bool _skipConfirmation = true;
  bool _landscape = true;
  double _autoDelay = 2;
  double _typewriter = 40;
  double _concurrency = 4;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final wide = constraints.maxWidth >= 880;
    final sections = [_audio(), _playback(), _storage(wide), _network()];
    return SingleChildScrollView(
      key: const PageStorageKey('settings-scroll'),
      padding: EdgeInsets.all(constraints.maxWidth < 600 ? 16 : 28),
      child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1240), child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ArchiveHeading('系统设置', 'SYSTEM PREFERENCES', trailing: ArchiveTag('交互预览', color: AppColors.yellow)),
          const SizedBox(height: 22),
          const PreviewNotice(text: '设置预览 · 滑块和开关仅保留本次界面状态，不影响实际播放、网络或存储，也不会持久保存。'),
          const SizedBox(height: 22),
          if (wide) Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Column(children: [sections[0], const SizedBox(height: 20), sections[2]])),
            const SizedBox(width: 20),
            Expanded(child: Column(children: [sections[1], const SizedBox(height: 20), sections[3]])),
          ]) else ...[
            for (final section in sections) ...[section, const SizedBox(height: 16)],
          ],
          const SizedBox(height: 24),
          const Text('明日方舟剧情播放器 · 产品界面预览\n剧情及素材权利归原权利人所有；数据来源 PRTS，使用前请确认相应授权。',
            textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.8)),
        ],
      ))),
    );
  });

  Widget _section(String title, String subtitle, IconData icon, List<Widget> children) => ArchivePanel(child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(children: [Icon(icon, color: AppColors.cyan, size: 19), const SizedBox(width: 10), Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)))]),
      const SizedBox(height: 6),
      Text(subtitle, style: const TextStyle(color: AppColors.muted, letterSpacing: 1.2, fontSize: 10)),
      const SizedBox(height: 12),
      ...children,
    ],
  ));

  Widget _audio() => _section('音频通道', 'AUDIO CHANNELS', Icons.graphic_eq, [
    for (final entry in _volumes.entries) _slider(
      entry.key, entry.value, 0, 100, '${entry.value.round()}%',
      (value) => setState(() => _volumes[entry.key] = value), divisions: 100,
    ),
    const Text('独立音量控制尚未接入音频引擎。', style: TextStyle(color: AppColors.muted, fontSize: 11)),
  ]);

  Widget _playback() => _section('演出偏好', 'PLAYBACK PREFERENCES', Icons.slow_motion_video, [
    _toggle('横屏沉浸播放', '屏幕方向设置预览', _landscape, (value) => setState(() => _landscape = value)),
    _slider('自动播放等待', _autoDelay, 1, 5, '${_autoDelay.round()} 秒', (value) => setState(() => _autoDelay = value), divisions: 4),
    _slider('逐字出字间隔', _typewriter, 10, 80, '${_typewriter.round()} ms', (value) => setState(() => _typewriter = value), divisions: 14),
    _toggle('跳过对白前确认', '防误触确认流程预留', _skipConfirmation, (value) => setState(() => _skipConfirmation = value)),
    const Divider(height: 24),
    const Text('文字样式预览', style: TextStyle(fontSize: 11, color: AppColors.muted)),
    const SizedBox(height: 10),
    Container(
      padding: const EdgeInsets.all(14), color: AppColors.canvas,
      child: const Text('「故事的下一页，等待你来翻开。」', style: TextStyle(fontSize: 14, height: 1.8)),
    ),
  ]);

  Widget _storage(bool wide) => _section('存储与缓存', 'STORAGE MANAGEMENT', Icons.storage_outlined, [
    _toggle('仅在 Wi-Fi 下下载', '移动网络下载策略预留', _wifiOnly, (value) => setState(() => _wifiOnly = value)),
    const Divider(height: 24),
    const Row(children: [Expanded(child: Text('素材占用', style: TextStyle(fontSize: 13))), ArchiveTag('未统计')]),
    const SizedBox(height: 12),
    Container(height: 5, color: AppColors.surface),
    const SizedBox(height: 10),
    const Text('文本 / 图片 / 音频 · 等待接入存储统计', style: TextStyle(color: AppColors.muted, fontSize: 11)),
    if (wide) ...[
      const Divider(height: 24),
      const Text('本地媒体缓存目录', style: TextStyle(fontSize: 13)),
      const SizedBox(height: 6),
      const Text('尚未接入目录管理', style: TextStyle(fontSize: 12, color: AppColors.muted)),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(onPressed: () => showPreviewMessage(context, '打开缓存目录'), icon: const Icon(Icons.folder_open, size: 16), label: const Text('打开目录')),
        OutlinedButton(onPressed: () => showPreviewMessage(context, '迁移缓存'), child: const Text('更改目录')),
      ]),
      _slider('并发下载数', _concurrency, 1, 8, '${_concurrency.round()}', (value) => setState(() => _concurrency = value), divisions: 7),
    ],
    const SizedBox(height: 16),
    OutlinedButton.icon(
      onPressed: () => showCachePreviewConfirmation(context),
      icon: const Icon(Icons.delete_outline, size: 17, color: AppColors.danger),
      label: const Text('清空素材缓存', style: TextStyle(color: AppColors.danger)),
    ),
  ]);

  Widget _network() => _section('关于与网络', 'ABOUT & NETWORK', Icons.public, [
    _toggle('强制离线模式', '仅预览开关，不会阻止网络请求', _offline, (value) => setState(() => _offline = value)),
    const Divider(height: 24),
    _statusRow('剧情索引', 'torappu.prts.wiki', '未检测'),
    const SizedBox(height: 16),
    _statusRow('素材分发节点', 'PRTS STATIC CDN', '未检测'),
    const SizedBox(height: 16),
    OutlinedButton.icon(onPressed: () => showPreviewMessage(context, '连接诊断'), icon: const Icon(Icons.network_check, size: 18), label: const Text('连接诊断')),
    const Divider(height: 24),
    _statusRow('客户端版本', 'ARKNIGHTS STORY PLAYER', '1.0.0'),
    const SizedBox(height: 12),
    const Text('免登录 · 按需点播\n离线归档与设置同步尚未开放。', style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.8)),
  ]);

  Widget _statusRow(String title, String description, String status) => Row(children: [
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 13)),
      const SizedBox(height: 5),
      Text(description, style: const TextStyle(fontSize: 10, color: AppColors.muted)),
    ])),
    const SizedBox(width: 8), ArchiveTag(status),
  ]);

  Widget _toggle(String title, String description, bool value, ValueChanged<bool> onChanged) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 5),
        Text(description, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
      ])),
      const SizedBox(width: 8),
      Semantics(label: '$title（预览）', child: Switch(value: value, onChanged: onChanged)),
    ]),
  );

  Widget _slider(String title, double value, double min, double max, String label, ValueChanged<double> onChanged, {required int divisions}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [Expanded(child: Text(title, style: const TextStyle(fontSize: 13))), Text(label, style: const TextStyle(color: AppColors.cyan, fontSize: 12))]),
      Semantics(label: '$title（预览）', child: Slider(
        key: ValueKey('setting-$title'), value: value, min: min, max: max,
        divisions: divisions, label: label, onChanged: onChanged,
      )),
    ]),
  );
}
