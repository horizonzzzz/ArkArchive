import 'dart:ui';

class StageImage {
  StageImage(this.key, {this.cg = false, this.fit = 'coverall'});
  final String key;
  final bool cg;
  final String fit;
  double alpha = 1, x = 0, y = 0, scaleX = 1, scaleY = 1;
}

class StageCharacter {
  StageCharacter(this.slot, this.name);
  final String slot;
  final String name;
  double alpha = 1,
      brightness = 1,
      x = 0,
      y = 0,
      scaleX = 1,
      scaleY = 1,
      angle = 0;
}

class DialogueLine {
  const DialogueLine(this.speaker, this.text, this.line);
  final String speaker, text;
  final int line;
}

class Choice {
  const Choice(this.label, this.value);
  final String label, value;
}

class InterludeFrame {
  InterludeFrame(this.channel);
  final String channel;
  Size size = Size.zero;
  Offset offset = Offset.zero;
  Offset scale = const Offset(1, 1);
  double alpha = 1;
  String avatar = '';
  bool visible = true;
}

class StageState {
  final List<StageImage> backgrounds = [], images = [];
  final List<StageCharacter> characters = [];
  final Map<String, InterludeFrame> interludes = {};
  final List<DialogueLine> history = [];
  List<Choice> choices = [];
  String speaker = '', text = '';
  int revealed = 0;
  bool dialogueVisible = false;
  double dialogueAlpha = 1;
  Color blockerColor = const Color(0xff000000);
  double blockerAlpha = 0;
  String blockerStyle = '';
  bool blockerInverse = false;
  final Map<int, double> curtains = {};
  final Map<String, double> focus = {};
  Offset shake = Offset.zero;
}
