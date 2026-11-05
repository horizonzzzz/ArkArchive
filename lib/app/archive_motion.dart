import 'package:flutter/material.dart';

abstract final class ArchiveMotion {
  static const pageDuration = Duration(milliseconds: 200);
  static const stateDuration = Duration(milliseconds: 160);

  static Duration duration(BuildContext context, Duration normal) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : normal;
}

/// 只为新内容提供入场过渡，不保留旧内容副本，避免重复操作与语义节点。
/// [child] 的挂载位置保持不变，可用于保留各页状态的 IndexedStack。
class ArchivePageTransition extends StatefulWidget {
  const ArchivePageTransition({
    super.key,
    required this.transitionKey,
    this.depth = 0,
    required this.child,
  });

  final Object? transitionKey;
  final int depth;
  final Widget child;

  @override
  State<ArchivePageTransition> createState() => _ArchivePageTransitionState();
}

class _ArchivePageTransitionState extends State<ArchivePageTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ArchiveMotion.pageDuration,
    value: 1,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  Animation<Offset> _position = const AlwaysStoppedAnimation(Offset.zero);
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _controller.value = 1;
  }

  @override
  void didUpdateWidget(ArchivePageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.transitionKey != oldWidget.transitionKey) {
      final direction = widget.depth.compareTo(oldWidget.depth);
      _position = Tween<Offset>(
        begin: Offset(.025 * direction, 0),
        end: Offset.zero,
      ).animate(_curve);
      if (_reduceMotion) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _curve,
    // 首帧透明时也保留语义与点击目标，快速切换不需要等待动画。
    alwaysIncludeSemantics: true,
    child: SlideTransition(position: _position, child: widget.child),
  );

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }
}

class ArchiveProgressIndicator extends StatelessWidget {
  const ArchiveProgressIndicator({
    super.key,
    required this.value,
    required this.semanticsLabel,
  });

  final double? value;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final target = value;
    final duration = ArchiveMotion.duration(
      context,
      ArchiveMotion.stateDuration,
    );
    if (target == null || duration == Duration.zero) {
      return LinearProgressIndicator(
        value: target,
        semanticsLabel: semanticsLabel,
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: target, end: target),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, progress, child) => LinearProgressIndicator(
        value: progress,
        semanticsLabel: semanticsLabel,
      ),
    );
  }
}
