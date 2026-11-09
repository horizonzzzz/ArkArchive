class PlaybackSettings {
  const PlaybackSettings({
    this.master = .8,
    this.bgm = .75,
    this.sfx = .85,
    this.voice = 0,
    this.autoDelay = 2,
    this.typingMs = 40,
    this.speedLevel = 0,
  });

  final double master, bgm, sfx, voice, autoDelay, typingMs;
  final int speedLevel;

  PlaybackSettings copyWith({
    double? master,
    double? bgm,
    double? sfx,
    double? voice,
    double? autoDelay,
    double? typingMs,
    int? speedLevel,
  }) => PlaybackSettings(
    master: master ?? this.master,
    bgm: bgm ?? this.bgm,
    sfx: sfx ?? this.sfx,
    voice: voice ?? this.voice,
    autoDelay: autoDelay ?? this.autoDelay,
    typingMs: typingMs ?? this.typingMs,
    speedLevel: speedLevel ?? this.speedLevel,
  );

  Map<String, double> toJson() => {
    'master': master,
    'bgm': bgm,
    'sfx': sfx,
    'voice': voice,
    'autoDelay': autoDelay,
    'typingMs': typingMs,
    'speedLevel': speedLevel.toDouble(),
  };

  factory PlaybackSettings.fromJson(Map<String, dynamic> json) {
    double value(String key, double fallback, double min, double max) {
      final n = json[key];
      return n is num && n.isFinite ? n.toDouble().clamp(min, max) : fallback;
    }

    return PlaybackSettings(
      master: value('master', .8, 0, 1),
      bgm: value('bgm', .75, 0, 1),
      sfx: value('sfx', .85, 0, 1),
      voice: value('voice', 0, 0, 1),
      autoDelay: value('autoDelay', 2, 1, 5),
      typingMs: value('typingMs', 40, 10, 80),
      speedLevel: value('speedLevel', 0, 0, 2).round(),
    );
  }
}
