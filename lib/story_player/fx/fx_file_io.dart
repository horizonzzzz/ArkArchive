import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readFxFile(Uri uri) => File.fromUri(uri).readAsBytes();
