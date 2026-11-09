import 'dart:async';
import 'package:flutter/material.dart';
import '../data/voice_pack.dart';
import '../runtime/dialogue_voice.dart';
import '../runtime/local_dialogue_voice.dart';

/// 设置页和播放器共享包状态、角色映射；试听使用独立的语音通道。
class VoicePackPanel extends StatefulWidget {
  const VoicePackPanel({super.key, required this.enabled, required this.onEnabledChanged,
    this.speakers = const [], this.previewVolume = .8, this.packs});
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final List<String> speakers;
  final double previewVolume;
  final VoicePackStore? packs;
  @override
  State<VoicePackPanel> createState() => _VoicePackPanelState();
}

class _VoicePackPanelState extends State<VoicePackPanel> {
  late final _packs = widget.packs ?? VoicePackStore.shared;
  DialogueVoice? _preview;
  String _speaker = '';
  bool _previewing = false;
  @override
  void initState() { super.initState(); unawaited(_packs.initialize()); }
  @override
  void dispose() { unawaited(_preview?.dispose()); super.dispose(); }

  Future<void> _download() async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('下载默认语音包'),
      content: const Text('将从国内镜像（hf-mirror.com，备用 HuggingFace）下载 Kokoro INT8 语音包（约 176 MB），安装需额外的临时磁盘空间。首次下载需要联网，安装后对白合成完全离线。使用移动数据会消耗流量。'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('下载'))],
    ));
    if (confirmed == true) await _packs.install();
  }
  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('删除语音包？'), content: const Text('删除后将停止对白语音，角色音色设置会保留。再次使用需要重新下载。'),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除'))],
    ));
    if (confirmed == true) { await _preview?.stop(); await _packs.remove(); }
  }
  Future<void> _audition() async {
    if (_previewing) { await _preview?.stop(); return; }
    setState(() => _previewing = true);
    try {
      final voice = _preview ??= createDialogueVoice(volume: widget.previewVolume, packs: _packs);
      await voice.setVolume(widget.previewVolume);
      await voice.speak(speaker: _speaker, text: '欢迎来到方舟档案室。行动即将开始，请做好准备。');
      if (mounted && voice.status.value == VoiceStatus.failed) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('试听失败，请检查语音包，或删除后重新下载。')));
      }
    } finally { if (mounted) setState(() => _previewing = false); }
  }
  Future<void> _bind(int? sid) async {
    await _preview?.stop();
    try { await _packs.bind(_speaker, sid); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('音色保存失败：$e'))); }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: _packs, builder: (context, _) {
    final speakers = <String>{'', ...widget.speakers, ...VoiceProfile.defaults.keys, ..._packs.profile.overrides.keys}.toList();
    final status = _packs.status;
    final downloading = status == VoicePackStatus.downloading || status == VoicePackStatus.paused;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SwitchListTile.adaptive(contentPadding: EdgeInsets.zero, title: const Text('对白语音'),
        subtitle: Text(_packs.supported ? '仅朗读当前对白；快速播放与长按快进时静音' : '当前平台暂不支持本地对白语音'),
        value: widget.enabled, onChanged: _packs.supported ? widget.onEnabledChanged : null),
      const SizedBox(height: 8),
      Row(children: [const Expanded(child: Text('Kokoro 多语言 · INT8')),
        Text(_packs.installed ? '已安装' : '约 176 MB', style: Theme.of(context).textTheme.labelMedium)]),
      const SizedBox(height: 8),
      Text(switch (status) {
        VoicePackStatus.unavailable => '支持 Android、Windows 和 Linux。',
        VoicePackStatus.missing => '尚未安装语音包，剧情继续以文字播放。',
        VoicePackStatus.downloading => '正在下载 ${(_packs.receivedBytes / 1000000).toStringAsFixed(1)} / ${(VoicePackStore.downloadBytes / 1000000).toStringAsFixed(1)} MB',
        VoicePackStatus.paused => '下载已暂停，再次打开应用也可继续下载。',
        VoicePackStatus.verifying => '正在校验并安装，请稍候…',
        VoicePackStatus.installed => '离线可用 · 本地占用 ${(_packs.installedBytes / 1000000).toStringAsFixed(1)} MB',
        VoicePackStatus.failed => '语音包不可用：${_packs.error ?? '请重新下载'}',
      }, style: Theme.of(context).textTheme.bodySmall),
      if (downloading || status == VoicePackStatus.verifying) ...[
        const SizedBox(height: 8), LinearProgressIndicator(value: downloading ? (_packs.receivedBytes / VoicePackStore.downloadBytes).clamp(0, 1) : null),
      ],
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 4, children: [
        if (_packs.supported && !_packs.busy && !_packs.installed)
          OutlinedButton.icon(onPressed: _download, icon: const Icon(Icons.download), label: Text(_packs.receivedBytes > 0 ? '继续下载' : '下载语音包')),
        if (downloading) OutlinedButton(onPressed: status == VoicePackStatus.paused ? _packs.resume : _packs.pause,
          child: Text(status == VoicePackStatus.paused ? '继续' : '暂停')),
        if (downloading) TextButton(onPressed: _packs.cancel, child: const Text('取消下载')),
        if (_packs.installed) TextButton.icon(onPressed: _remove, icon: const Icon(Icons.delete_outline), label: const Text('删除语音包')),
      ]),
      const Divider(height: 28),
      const Text('角色音色'), const SizedBox(height: 8),
      DropdownButtonFormField<String>(initialValue: _speaker, isExpanded: true,
        decoration: const InputDecoration(labelText: '角色'),
        items: [for (final speaker in speakers) DropdownMenuItem(value: speaker, child: Text(speaker.isEmpty ? '旁白' : speaker))],
        onChanged: (value) { if (value != null) { unawaited(_preview?.stop()); setState(() => _speaker = value); } }),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(key: ValueKey('$_speaker:${_packs.profile.resolve(_speaker)}'),
        initialValue: _packs.profile.resolve(_speaker), isExpanded: true,
        decoration: const InputDecoration(labelText: '音色'),
        items: [for (var sid = 3; sid <= 102; sid++) DropdownMenuItem(value: sid, child: Text(VoiceProfile.label(sid)))],
        onChanged: _packs.supported ? _bind : null),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(onPressed: _packs.installed && widget.previewVolume > 0 ? _audition : null,
          icon: Icon(_previewing ? Icons.stop : Icons.volume_up_outlined), label: Text(_previewing ? '停止试听' : '试听')),
        TextButton(onPressed: _packs.profile.overrides.containsKey(_speaker) ? () => _bind(null) : null, child: const Text('恢复默认音色')),
      ]),
      Text(_packs.profile.overrides.containsKey(_speaker) ? '已指定音色；同名角色在所有章节生效。' : '使用默认分配；未收录的角色会按名称稳定分配音色。', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      const Text('模型：Kokoro v1.1（Apache-2.0） · 推理：sherpa-onnx · 下载：国内镜像优先，官方源兑底\n离线合成可能读错人名或生僻字，可关闭语音继续阅读。', style: TextStyle(fontSize: 11)),
    ]);
  });
}
