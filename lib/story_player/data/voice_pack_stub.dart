import 'voice_pack.dart';

VoicePackStore createVoicePackStore() => UnsupportedVoicePackStore();

class UnsupportedVoicePackStore extends VoicePackStore {
  @override
  VoicePackStatus get status => VoicePackStatus.unavailable;
  @override
  final profile = VoiceProfile();
  @override
  String? get directory => null;
  @override
  String? get error => null;
  @override
  int get receivedBytes => 0;
  @override
  int get installedBytes => 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> install() async {}
  @override
  void pause() {}
  @override
  void resume() {}
  @override
  void cancel() {}
  @override
  Future<void> remove() async {}
  @override
  Future<void> bind(String speaker, int? sid) async {}
}
