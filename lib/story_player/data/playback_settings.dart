class PlaybackSettings {
  const PlaybackSettings({
    this.master = .8,
    this.bgm = .75,
    this.sfx = .85,
    this.autoDelay = 2,
    this.typingMs = 40,
    this.lightTheme = false,
  });

  final double master, bgm, sfx, autoDelay, typingMs;
  final bool lightTheme;

  PlaybackSettings copyWith({
    double? master,
    double? bgm,
    double? sfx,
    double? autoDelay,
    double? typingMs,
    bool? lightTheme,
  }) => PlaybackSettings(
    master: master ?? this.master,
    bgm: bgm ?? this.bgm,
    sfx: sfx ?? this.sfx,
    autoDelay: autoDelay ?? this.autoDelay,
    typingMs: typingMs ?? this.typingMs,
    lightTheme: lightTheme ?? this.lightTheme,
  );

  Map<String, Object> toJson() => {
    'master': master,
    'bgm': bgm,
    'sfx': sfx,
    'autoDelay': autoDelay,
    'typingMs': typingMs,
    'lightTheme': lightTheme,
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
      autoDelay: value('autoDelay', 2, 1, 5),
      typingMs: value('typingMs', 40, 10, 80),
      lightTheme: json['lightTheme'] == true,
    );
  }
}
