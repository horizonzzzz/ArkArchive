import 'package:arknights_story_player/app/archive_motion.dart';
import 'package:arknights_story_player/app/archive_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _pages(int index, {int depth = 0, bool reduceMotion = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: ArchivePageTransition(
            transitionKey: index,
            depth: depth,
            child: IndexedStack(
              index: index,
              children: const [
                TextField(key: ValueKey('first')),
                TextField(key: ValueKey('second')),
              ],
            ),
          ),
        ),
      ),
    );

Finder _insideTransition(Type type) => find.descendant(
  of: find.byType(ArchivePageTransition),
  matching: find.byType(type),
);

Widget _progress(double value, {bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(
      body: ArchiveProgressIndicator(value: value, semanticsLabel: '测试缓存进度'),
    ),
  ),
);

Widget _header(bool expanded, {bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(
      body: Column(
        children: [
          ArchivePageHeader(
            key: const ValueKey('header'),
            title: '章节',
            bottom: expanded
                ? const SizedBox(height: 48, child: Text('操作'))
                : null,
          ),
          const Expanded(child: SizedBox()),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('选择栏平滑展开，中途开启减少动画时直接完成布局', (tester) async {
    final header = find.byKey(const ValueKey('header'));
    await tester.pumpWidget(_header(false));
    final collapsed = tester.getSize(header).height;
    await tester.pumpWidget(_header(true));
    expect(tester.getSize(header).height, collapsed);
    await tester.pump(const Duration(milliseconds: 60));
    final middle = tester.getSize(header).height;
    expect(middle, greaterThan(collapsed));
    await tester.pumpWidget(_header(true, reduceMotion: true));
    expect(tester.getSize(header).height, greaterThan(middle));
    await tester.pumpWidget(_header(false, reduceMotion: true));
    expect(tester.getSize(header).height, collapsed);
    expect(tester.takeException(), isNull);
  });

  testWidgets('转场保留 IndexedStack 内页面状态且不复制内容', (tester) async {
    await tester.pumpWidget(_pages(0));
    await tester.enterText(find.byKey(const ValueKey('first')), '保留搜索');
    final firstState = tester.state(find.byKey(const ValueKey('first')));
    await tester.pumpWidget(_pages(1));
    expect(
      tester
          .widget<FadeTransition>(_insideTransition(FadeTransition))
          .opacity
          .value,
      0,
    );
    await tester.pump(const Duration(milliseconds: 50));
    final opacity = tester
        .widget<FadeTransition>(_insideTransition(FadeTransition))
        .opacity
        .value;
    expect(opacity, greaterThan(0));
    expect(opacity, lessThan(1));
    expect(find.byKey(const ValueKey('second')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('second')), '可以立即输入');
    await tester.pumpWidget(_pages(0));
    await tester.pumpAndSettle();
    expect(
      identical(tester.state(find.byKey(const ValueKey('first'))), firstState),
      isTrue,
    );
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '保留搜索',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('层级进退方向相反，平级切换没有横移', (tester) async {
    await tester.pumpWidget(_pages(0));
    await tester.pumpWidget(_pages(1, depth: 1));
    expect(
      tester
          .widget<SlideTransition>(_insideTransition(SlideTransition))
          .position
          .value
          .dx,
      greaterThan(0),
    );
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(_pages(0));
    expect(
      tester
          .widget<SlideTransition>(_insideTransition(SlideTransition))
          .position
          .value
          .dx,
      lessThan(0),
    );
    await tester.pumpWidget(_pages(1));
    expect(
      tester
          .widget<SlideTransition>(_insideTransition(SlideTransition))
          .position
          .value,
      Offset.zero,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动画时立即显示目标页，动态开启也会停止当前转场', (tester) async {
    await tester.pumpWidget(_pages(0));
    await tester.pumpWidget(_pages(1, depth: 1));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(_pages(1, depth: 1, reduceMotion: true));
    expect(
      tester
          .widget<FadeTransition>(_insideTransition(FadeTransition))
          .opacity
          .value,
      1,
    );
    expect(
      tester
          .widget<SlideTransition>(_insideTransition(SlideTransition))
          .position
          .value,
      Offset.zero,
    );
    await tester.pumpWidget(_pages(0, reduceMotion: true));
    expect(
      tester
          .widget<FadeTransition>(_insideTransition(FadeTransition))
          .opacity
          .value,
      1,
    );
    expect(
      tester
          .widget<SlideTransition>(_insideTransition(SlideTransition))
          .position
          .value,
      Offset.zero,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存进度平滑更新，并在有限时间内收敛', (tester) async {
    await tester.pumpWidget(_progress(.2));
    await tester.pumpWidget(_progress(.8));
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .2,
    );
    await tester.pump(const Duration(milliseconds: 60));
    final value = tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .value!;
    expect(value, greaterThan(.2));
    expect(value, lessThan(.8));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .8,
    );
  });

  testWidgets('减少动画时缓存进度直接更新', (tester) async {
    await tester.pumpWidget(_progress(.2, reduceMotion: true));
    await tester.pumpWidget(_progress(.8, reduceMotion: true));
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .8,
    );
  });
}
