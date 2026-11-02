import '../script.dart';

abstract class StoryAudio {
  Future<void> execute(StoryCommand command);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> dispose();
}

class SilentStoryAudio implements StoryAudio {
  @override
  Future<void> execute(StoryCommand command) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
