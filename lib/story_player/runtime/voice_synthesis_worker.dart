import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// native 模型仅在此 isolate 内创建、调用和释放。
class VoiceSynthesisWorker {
  Isolate? _isolate;
  ReceivePort? _port;
  SendPort? _commands;
  Future<void>? _loading;
  final _pending = <int, Completer<Uint8List>>{};
  var _nextId = 0;
  bool _disposed = false;
  Completer<void>? _closed;

  Future<void> _load(String directory) => _loading ??= _start(directory);
  Future<void> _start(String directory) async {
    if (_disposed) throw StateError('语音引擎已关闭');
    final ready = Completer<void>();
    final port = _port = ReceivePort();
    port.listen((dynamic message) {
      if (message == 'closed') {
        if (_closed != null && !_closed!.isCompleted) _closed!.complete();
        return;
      }
      if (message is SendPort) {
        _commands = message;
        if (!ready.isCompleted) ready.complete();
      } else if (message is Map) {
        final id = message['id'] as int?;
        if (id == null) {
          if (!ready.isCompleted) ready.completeError(StateError('${message['error']}'));
        } else {
          final pending = _pending.remove(id);
          if (message['error'] != null) {
            pending?.completeError(StateError('${message['error']}'));
          } else {
            pending?.complete((message['wav'] as TransferableTypedData).materialize().asUint8List());
          }
        }
      }
    });
    _isolate = await Isolate.spawn(_voiceWorkerMain, [port.sendPort, directory]);
    await ready.future.timeout(const Duration(seconds: 90));
  }

  Future<Uint8List> synthesize(String directory, String text, int sid) async {
    await _load(directory);
    if (_disposed) throw StateError('语音引擎已关闭');
    final id = _nextId++;
    final result = Completer<Uint8List>();
    _pending[id] = result;
    _commands!.send({'id': id, 'text': text, 'sid': sid});
    try {
      return await result.future.timeout(const Duration(minutes: 3));
    } finally { _pending.remove(id); }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final item in _pending.values) {
      item.completeError(StateError('语音引擎已关闭'));
    }
    _pending.clear();
    try {
      if (_loading != null) await _loading;
      if (_commands != null) {
        _closed = Completer<void>();
        _commands!.send(null);
        await _closed!.future.timeout(const Duration(minutes: 3));
      }
    } catch (_) {
      _isolate?.kill(priority: Isolate.immediate);
    }
    _port?.close();
  }
}

void _voiceWorkerMain(List<Object> args) {
  final replies = args[0] as SendPort;
  final root = args[1] as String;
  sherpa.OfflineTts? tts;
  final commands = ReceivePort();
  try {
    sherpa.initBindings();
    final rules = ['date-zh.fst', 'number-zh.fst', 'phone-zh.fst']
        .map((name) => '$root/$name').where((path) => File(path).existsSync()).join(',');
    tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        kokoro: sherpa.OfflineTtsKokoroModelConfig(
          model: '$root/model.int8.onnx', voices: '$root/voices.bin',
          tokens: '$root/tokens.txt',
          lexicon: '$root/lexicon-zh.txt,$root/lexicon-us-en.txt', lang: 'zh',
        ), numThreads: 2,
      ), ruleFsts: rules, maxNumSentences: 1,
    ));
    if (tts.numSpeakers < 103) throw StateError('模型音色数量不匹配');
    replies.send(commands.sendPort);
    commands.listen((dynamic message) {
      if (message == null) {
        tts?.free();
        tts = null;
        commands.close();
        replies.send('closed');
        return;
      }
      final data = message as Map;
      try {
        final audio = tts!.generate(text: data['text'] as String, sid: data['sid'] as int);
        if (audio.samples.isEmpty) throw StateError('未生成语音，请检查模型与词典');
        replies.send({'id': data['id'], 'wav': TransferableTypedData.fromList([encodeVoiceWav(audio.samples, audio.sampleRate)])});
      } catch (e) { replies.send({'id': data['id'], 'error': '$e'}); }
    });
  } catch (e) {
    tts?.free();
    commands.close();
    replies.send({'error': '$e'});
  }
}

Uint8List encodeVoiceWav(Float32List samples, int sampleRate) {
  final result = Uint8List(44 + samples.length * 2);
  final data = ByteData.sublistView(result);
  void ascii(int at, String value) => result.setRange(at, at + value.length, value.codeUnits);
  ascii(0, 'RIFF'); data.setUint32(4, result.length - 8, Endian.little);
  ascii(8, 'WAVE'); ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little); data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little); data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little); data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little); ascii(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return result;
}
