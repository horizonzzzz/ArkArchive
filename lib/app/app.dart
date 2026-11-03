import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'story_launcher.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '明日方舟剧情播放器',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    home: const StoryLauncher(),
  );
}
