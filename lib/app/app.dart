import 'package:flutter/material.dart';
import 'story_launcher.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '明日方舟剧情播放器', debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: const Color(0xff111315), colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffadb6be), brightness: Brightness.dark)),
    home: const StoryLauncher(),
  );
}
