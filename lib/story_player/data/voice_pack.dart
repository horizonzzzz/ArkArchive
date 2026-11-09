import 'package:flutter/foundation.dart';
import 'voice_profile.dart';
import 'voice_pack_stub.dart' if (dart.library.io) 'voice_pack_io.dart' as platform;

export 'voice_profile.dart';

enum VoicePackStatus { unavailable, missing, downloading, paused, verifying, installed, failed }

class VoicePackFile {
  const VoicePackFile(this.name, this.size, this.sha256);
  final String name;
  final int size;
  final String sha256;
}

abstract class VoicePackStore extends ChangeNotifier {
  /// 删除模型前等待所有使用者释放 native 文件句柄。
  final releaseUsers = <Future<void> Function()>{};
  static final VoicePackStore shared = platform.createVoicePackStore();
  static const id = 'kokoro-int8-multi-lang-v1_1';

  /// 下载源按优先级排列：hf-mirror 国内镜像优先，HuggingFace 官方兜底；
  /// 任一源失败（网络错误、HTTP 异常、哈希不符）自动尝试下一个源。
  static const downloadHosts = ['https://hf-mirror.com', 'https://huggingface.co'];
  static const packRepo = 'csukuangfj/kokoro-int8-multi-lang-v1_1';

  /// 文件哈希来源：LFS 文件为 HuggingFace 仓库的 git-lfs oid（即上游权威
  /// sha256），小文件为从镜像实测的 sha256；整包校验不再依赖 GitHub tar.bz2。
  static const files = <VoicePackFile>[
    VoicePackFile('model.int8.onnx', 114203914, '05d793700b0b507f760c183c0e39bdd6a97b43d32fdc7bf7b54a5179f1b11222'),
    VoicePackFile('voices.bin', 53790720, 'e64a5a581d8c2a350d848f51c3121657cd83aa07ed6109172177345874a7244c'),
    VoicePackFile('lexicon-us-en.txt', 5956885, '7daaab53a181be9885b853a8582bf1838186317e5dadacbcef9c426d6fa0da14'),
    VoicePackFile('lexicon-zh.txt', 2120131, 'fea060803db3e59193987f1a3436f56917bda09f3b3595b6588e46ae60cebf93'),
    VoicePackFile('tokens.txt', 1111, '931ab2df2400cd65d580a22402024c2347ced8ae9ea300e545144b1aacc48e14'),
    VoicePackFile('date-zh.fst', 59154, 'eb8aa079ae3cb81d8f4404992f39d61a0cb990947512b5b8d1e54d1f6980e718'),
    VoicePackFile('number-zh.fst', 64482, '743f402181fcfebf76cc2f0546b71fa26476e626fbe4e460fb7b4c3a7a8bd5bd'),
    VoicePackFile('phone-zh.fst', 88630, '1ac2b6fa56b1442320c4de7db08353bab8963a2b57f365eebcdd3a2d3562f8d7'),
  ];

  static int get downloadBytes => files.fold(0, (sum, file) => sum + file.size);
  static String fileUrl(String host, String name) => '$host/$packRepo/resolve/main/$name';

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
