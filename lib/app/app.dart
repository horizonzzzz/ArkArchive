import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'story_launcher.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '方舟档案室',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    home: const StoryLauncher(),
  );
}
