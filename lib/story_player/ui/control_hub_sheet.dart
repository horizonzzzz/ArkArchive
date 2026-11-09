import 'package:flutter/material.dart';
import '../data/playback_settings.dart';
import '../runtime/story_engine.dart';
import 'voice_pack_panel.dart';

class ControlHubSheet extends StatefulWidget {
  const ControlHubSheet({super.key, required this.engine, required this.settings,
    required this.onSettingsChanged, this.speakers = const []});
  final StoryEngine engine;
  final PlaybackSettings settings;
  final ValueChanged<PlaybackSettings> onSettingsChanged;
  final List<String> speakers;
  @override
  State<ControlHubSheet> createState() => _ControlHubSheetState();
}

class _ControlHubSheetState extends State<ControlHubSheet> {
  late PlaybackSettings _settings = widget.settings;
  void _change(PlaybackSettings value) {
    setState(() => _settings = value);
    widget.onSettingsChanged(value);
  }
  Widget _volume(String label, double value, ValueChanged<double> change) =>
    Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [Expanded(child: Text(label)), Text('${(value * 100).round()}%')]),
      Slider(value: value, divisions: 100, label: '${(value * 100).round()}%', onChanged: change),
    ]);
  Widget _heading(String text) => Padding(padding: const EdgeInsets.only(top: 16, bottom: 12),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium));
  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xff12171b),
    child: SafeArea(child: SizedBox(width: MediaQuery.sizeOf(context).width.clamp(0, 420),
      child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 10, 8, 0), child: Row(children: [
          const Expanded(child: Text('控制中心', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
          IconButton(tooltip: '关闭控制中心', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
        ])),
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: AnimatedBuilder(animation: widget.engine, builder: (context, _) {
            final engine = widget.engine;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _heading('播放节奏'),
              SegmentedButton<String>(segments: const [
                ButtonSegment(value: 'default', label: Text('手动')),
                ButtonSegment(value: 'button_auto', label: Text('自动')),
                ButtonSegment(value: 'quick_play', label: Text('快速')),
              ], selected: {engine.autoMode}, showSelectedIcon: false,
                onSelectionChanged: (value) => engine.setAutoMode(value.first)),
              const SizedBox(height: 16),
              SegmentedButton<int>(segments: [for (var i = 0; i < 3; i++)
                ButtonSegment(value: i, label: Text(['I · 舒缓', 'II · 标准', 'III · 紧凑'][i]), enabled: engine.autoMode == 'button_auto')],
                selected: {engine.speedLevel.clamp(0, 2)}, showSelectedIcon: false,
                onSelectionChanged: engine.autoMode == 'button_auto' ? (value) {
                  engine.setSpeedLevel(value.first);
                  _change(_settings.copyWith(speedLevel: value.first));
                } : null),
              const SizedBox(height: 8),
              Text(engine.autoMode == 'button_auto' ? '朗读结束后再推进下一句；控制中心关闭后继续播放。' : '速度档仅在自动播放时可调。快速播放会停止对白语音。',
                style: Theme.of(context).textTheme.bodySmall),
              SwitchListTile.adaptive(contentPadding: EdgeInsets.zero, title: const Text('剧场模式'),
                subtitle: const Text('关闭面板后隐藏工具栏，轻触舞台恢复'), value: engine.theaterMode,
                onChanged: engine.setTheaterMode),
              const Divider(height: 20), _heading('音频通道'),
              _volume('主音量', _settings.master, (v) => _change(_settings.copyWith(master: v))),
              _volume('背景音乐 BGM', _settings.bgm, (v) => _change(_settings.copyWith(bgm: v))),
              _volume('音效与环境 SFX', _settings.sfx, (v) => _change(_settings.copyWith(sfx: v))),
              _volume('对白语音', _settings.voice, (v) => _change(_settings.copyWith(voice: v))),
              const Divider(height: 20), _heading('对白语音'),
              VoicePackPanel(enabled: _settings.voice > 0, previewVolume: _settings.master * .9,
                speakers: widget.speakers, onEnabledChanged: (enabled) => _change(_settings.copyWith(voice: enabled ? .9 : 0))),
            ]);
          }))),
      ]))),
  );
}
