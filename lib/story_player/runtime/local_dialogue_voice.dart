import '../data/voice_pack.dart';
import 'dialogue_voice.dart';
import './local_dialogue_voice_stub.dart'
    if (dart.library.io) 'local_dialogue_voice_io.dart' as platform;

DialogueVoice createDialogueVoice({required double volume, VoicePackStore? packs}) =>
    platform.createLocalDialogueVoice(packs ?? VoicePackStore.shared, volume);
