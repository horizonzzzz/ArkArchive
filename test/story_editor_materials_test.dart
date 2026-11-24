import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:arknights_story_player/story_editor/editor_materials.dart';
import 'package:arknights_story_player/story_editor/editor_platform.dart';
import 'package:arknights_story_player/story_editor/editor_preview.dart';
import 'package:arknights_story_player/story_editor/editor_project.dart';
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'story_export_test.dart' show MemoryCache;

class _Storage extends EditorStorage {
  @override
  Future<(String, Uint8List)?> pickMedia({required bool image}) async => null;
}

void main() {
  testWidgets('素材选择器可跳到指定页，缩略图加载时显示进度', (tester) async {
    final nextPageImage = Completer<http.Response>();
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jXioAAAAASUVORK5CYII=',
    );
    final store = AssetStore(
      cache: MemoryCache(),
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/story-resources/explore') {
          final page = request.url.queryParameters['page'];
          final ids = page == '1'
              ? List.generate(
                  24,
                  (index) => 'cg_${index.toString().padLeft(2, '0')}',
                )
              : ['cg_24'];
          return http.Response(
            jsonEncode({
              'pageCount': 2,
              'entries': [
                for (final id in ids)
                  {
                    'resource': {'type': 'image', 'id': id},
                  },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/cg_24.png')) {
          return nextPageImage.future;
        }
        if (request.url.path.endsWith('.png')) {
          return http.Response.bytes(
            image,
            200,
            headers: {'content-type': 'image/png'},
          );
        }
        return http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(store.close);
    final resources = EditorPreviewResources(store);
    addTearDown(resources.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorMaterialPicker(
            field: const EditorField('image', '插图 / CG', FieldType.cg),
            current: '',
            resources: resources,
            assets: const {},
            storage: _Storage(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('cg_23'), findsOneWidget);
    expect(find.text('cg_24'), findsNothing);

    await tester.tap(find.byTooltip('选择页数'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('2').last);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('cg_24'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.text('cg_23'), findsNothing);

    nextPageImage.complete(
      http.Response.bytes(image, 200, headers: {'content-type': 'image/png'}),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
