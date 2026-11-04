export 'file_cache_stub.dart'
    if (dart.library.io) 'file_cache_io.dart'
    if (dart.library.js_interop) 'file_cache_web.dart';
