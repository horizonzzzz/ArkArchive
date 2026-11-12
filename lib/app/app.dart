import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'story_launcher.dart';

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _lightTheme = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '方舟档案室',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(light: _lightTheme),
    home: StoryLauncher(
      onThemeChanged: (value) {
        if (_lightTheme != value) setState(() => _lightTheme = value);
      },
    ),
  );
}
