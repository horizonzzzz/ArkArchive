import 'dart:ui';

class StageImage {
  StageImage(this.key, {this.cg = false, this.fit = 'coverall'});
  final String key;
  final bool cg;
  /// screenadapt；空值表示不缩放，直接按原图尺寸展示。
  String fit;
  double alpha = 1, x = 0, y = 0, scaleX = 1, scaleY = 1;
  bool tiled = false;
  double widthScale = 1, heightScale = 1;
}

/// gridbg / verticalbg / largebg / largeimg 的多图拼接场景。
class LargeScene {
  LargeScene({
    required this.tiles,
    required this.solidWidths,
    required this.solidHeights,
    required this.layout,
    this.initPositionMode = 'default',
  });
  final List<StageImage> tiles;
  final List<double> solidWidths, solidHeights;
  /// grid（2×2）、vertical（纵向堆叠）、large（左右拼接）。
  final String layout;
  final String initPositionMode;
  double alpha = 1, x = 0, y = 0, scaleX = 1, scaleY = 1;
}

class StageCharacter {
  StageCharacter(this.slot, this.name);
  final String slot;
  final String name;
  /// 附加透明度（charslot 的 afrom/ato、切入窗口共用）。
  double contentAlpha = 1;
  double alpha = 1, brightness = 1;
  /// characteraction / charslot action 的运动位移与缩放。
  double actionX = 0, actionY = 0, scaleX = 1, scaleY = 1;
  double zoomShiftX = 0, zoomShiftY = 0;
  double jumpOffsetY = 0;
  double shakeOffsetX = 0, shakeOffsetY = 0;
  double rotationDeg = 0;
  /// 边缘黑化（0~1 高度比例），参考端烘焙进立绘纹理。
  double blackStart = -1, blackEnd = -1;
}

class DialogueLine {
  const DialogueLine(this.speaker, this.text, this.line);
  final String speaker, text;
  final int line;
}

class Choice {
  const Choice(this.label, this.value, {this.disabled = false});
  final String label, value;
  final bool disabled;
}

/// 自由坐标旁白（subtitle）与富文本贴纸（sticker）共用一套排版状态。
class OverlayText {
  OverlayText(this.id, {required this.x, required this.y, required this.width, required this.size, required this.alignment});
  final String id;
  double x, y, width, size;
  String alignment;
  String text = '';
  double alpha = 0;
  int revealed = 0;
  double typingMs = 40;
  double typingTime = 0;
  double rotation = 0;
  bool visible = false;
}

class TimerSticker {
  TimerSticker({required this.x, required this.y, required this.width, required this.size});
  final double x, y, width, size;
  double alpha = 0;
  int limitSeconds = -1;
  int elapsedSeconds = -1;
  bool visible = false;
  /// 计时启动时间（引擎微秒时钟），-1 表示未启动。
  double startMicros = -1;
}

/// animtext 地点印章的逐帧状态。
class LocationStamp {
  LocationStamp(this.position, this.segments, this.style);
  final Offset position;
  final List<String> segments;
  final String style;
  double alpha = 0;
  /// 0~5000ms 的动画进度。
  double elapsedMs = 0;
}

class InterludeElement {
  InterludeElement(this.key);
  final String key;
  String image = '';
  double alpha = 0;
  Offset offset = Offset.zero;
  Offset scale = const Offset(1, 1);
  bool visible = false;
}

class InterludeFrame {
  InterludeFrame(this.channel);
  final String channel;
  /// maskid 模板；空串为普通矩形窗口。
  String maskId = '';
  int type = 0;
  String style = '';
  String slot = '';
  Offset size = Offset.zero;
  Offset offset = Offset.zero;
  Offset templateScale = const Offset(1, 1);
  double alpha = 1;
  String name = '';
  String charName = '';
  String avatar = '';
  bool visible = true;
  final Map<String, InterludeElement> elements = {};
  Offset dialogCharOffset = Offset.zero;
  Offset dialogCharScale = const Offset(1, 1);
  /// 淡出会话哨兵：再次隐藏/更新时使旧的淡出完成回调失效（参考端 scaleGen 语义）。
  int hideEpoch = 0;
}

class CutinCharacter {
  CutinCharacter(this.name, this.alpha);
  final String name;
  double alpha;
}
class CutinWindow {
  CutinWindow(this.widgetId);
  final String widgetId;
  double rootX = 640, rootY = 360;
  double contentX = 0, contentY = 0;
  double zoom = 1;
  double maskW = 0, maskH = 0;
  double targetW = 200, targetH = 720;
  String fadeStyle = 'fade';
  double alpha = 1;
  /// 0=横向展开，1=纵向展开（遮罩收拢方向）。
  int expandAxis = 0;
  final List<CutinCharacter> characters = [];
  double charOffsetX = 0, charOffsetY = 0;
  /// 隐藏会话哨兵：参考端 ++sessionId；淡出完成后才从场景移除。
  int hideEpoch = 0;
}

class CgItem {
  CgItem(this.key, this.image);
  final String key;
  final String image;
  double alpha = 1, x = 0, y = 0, scale = 1, rotation = 0;
  double width = 0, height = 0;
  Color? tint;
  double tintAlpha = 1;
  /// 隐藏会话哨兵（参考端 hideEpoch）：连续 hide 时仅最后一次淡出负责移除。
  int hideEpoch = 0;
}

class AvgDisplayItem {
  AvgDisplayItem(this.id, this.slot, this.name);
  final String id;
  /// bgover / charover / cgover。
  final String slot;
  final String name;
  double alpha = 1;
}

class ShowItem {
  ShowItem({required this.style, required this.image, required this.width, required this.offsetX, required this.offsetY, required this.blackAlpha, required this.fadeStyle});
  final String style;
  final String image;
  final double width;
  final double offsetX, offsetY;
  final double blackAlpha;
  final String fadeStyle;
  double alpha = 1;
  double maskW = 0, maskH = 720;
  /// 隐藏会话哨兵：淡出完成后才从场景移除。
  int hideEpoch = 0;
}

class HeaderMeta {
  const HeaderMeta({this.fitMode = 'DEFAULT', this.title = '', this.isVideoOnly = false, this.isTutorial = false, this.isSkippable = true, this.isAutoable = true});
  final String fitMode;
  final String title;
  final bool isVideoOnly;
  final bool isTutorial;
  final bool isSkippable;
  final bool isAutoable;
}

class StageState {
  final List<StageImage> backgrounds = [], images = [];
  final List<LargeScene> largeScenes = [], largeImages = [];
  final List<StageCharacter> characters = [];
  final Map<String, InterludeFrame> interludes = {};
  final Map<String, CutinWindow> cutins = {};
  final Map<String, CgItem> cgItems = {};
  final Map<String, AvgDisplayItem> avgDisplays = {};
  final List<ShowItem> showItems = [];
  final List<LocationStamp> stamps = [];
  final List<DialogueLine> history = [];
  OverlayText? subtitle;
  final Map<String, OverlayText> stickers = {};
  TimerSticker? timer;
  List<Choice> choices = [];
  String speaker = '', text = '';
  int revealed = 0;
  bool dialogueVisible = false;
  double dialogueAlpha = 1;
  Color blockerColor = const Color(0xff000000);
  double blockerAlpha = 0;
  String blockerStyle = '';
  String blockerImage = '';
  bool blockerInverse = false;
  final Map<int, CurtainState> curtains = {};
  final Map<String, double> focus = {};
  Offset shake = Offset.zero;
  double grayscale = 0, inverse = 0;
  /// imagetween 场景层旋转（度）。
  double imageRotation = 0;
  bool focusBlur = true;
  String focusColor = 'None';
  HeaderMeta metadata = const HeaderMeta();
}

class CurtainState {
  CurtainState(this.direction);
  final int direction;
  double fill = 0, alpha = 1;
  bool grad = false;
}
