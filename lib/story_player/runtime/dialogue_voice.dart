import 'package:flutter/foundation.dart';

/// speak 在该句播放完或被打断后完成，供自动播放等待句尾。
abstract class DialogueVoice {
  ValueListenable<VoiceStatus> get status;
  Future<void> speak({required String speaker, required String text, int? requestId});
  Future<void> stop();
  Future<void> pause();
  Future<void> resume();
  Future<void> setVolume(double volume);
  Future<void> dispose();
}

enum VoiceStatus { unavailable, idle, synthesizing, speaking, paused, failed }

class SilentDialogueVoice implements DialogueVoice {
  final _status = ValueNotifier(VoiceStatus.unavailable);
  @override
  ValueListenable<VoiceStatus> get status => _status;
  @override
  Future<void> speak({required String speaker, required String text, int? requestId}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async => _status.dispose();
}
