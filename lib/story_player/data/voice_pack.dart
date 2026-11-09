import 'package:flutter/foundation.dart';
import 'voice_profile.dart';
import 'voice_pack_stub.dart' if (dart.library.io) 'voice_pack_io.dart' as platform;

export 'voice_profile.dart';

enum VoicePackStatus { unavailable, missing, downloading, paused, verifying, installed, failed }

abstract class VoicePackStore extends ChangeNotifier {
  /// 删除模型前等待所有使用者释放 native 文件句柄。
  final releaseUsers = <Future<void> Function()>{};
  static final VoicePackStore shared = platform.createVoicePackStore();
  static const id = 'kokoro-int8-multi-lang-v1_1';
  static const downloadBytes = 147052523;
  static const archiveSha256 = '259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c';
  static const downloadUrl = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2';
  static const assetApiUrl = 'https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/assets/677614055';

  VoicePackStatus get status;
  VoiceProfile get profile;
  String? get directory;
  String? get error;
  int get receivedBytes;
  int get installedBytes;
  bool get supported => status != VoicePackStatus.unavailable;
  bool get installed => status == VoicePackStatus.installed;
  bool get busy => status == VoicePackStatus.downloading || status == VoicePackStatus.paused || status == VoicePackStatus.verifying;
  Future<void> initialize();
  Future<void> install();
  void pause();
  void resume();
  void cancel();
  Future<void> remove();
  Future<void> bind(String speaker, int? sid);
}
