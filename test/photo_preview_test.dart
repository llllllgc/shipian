import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:raw_jpg_picker/app_controller.dart';
import 'package:raw_jpg_picker/core/converter.dart';
import 'package:raw_jpg_picker/core/integrity.dart';
import 'package:raw_jpg_picker/core/models.dart';
import 'package:raw_jpg_picker/core/photo_preview.dart';
import 'package:raw_jpg_picker/ui/palette.dart';
import 'package:raw_jpg_picker/ui/photo_viewer.dart';
import 'package:raw_jpg_picker/ui/preview_pane.dart';

class PreviewDecoder implements RawDecoder {
  PreviewDecoder({this.before});
  final Future<void> Function(String, CancellationToken)? before;
  final calls = <String>[];
  @override
  Future<void> decode({
    required String input,
    required String output,
    required ImageFormat format,
    required int quality,
    required CancellationToken token,
  }) async {
    calls.add(p.basename(input));
    await before?.call(input, token);
    token.check();
    await File('test/fixtures/preview.jpg').copy(output);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, cache;
  late File raw;
  setUp(() async {
    root = Directory(
      await (await Directory.systemTemp.createTemp(
        'shipian_preview_',
      )).resolveSymbolicLinks(),
    );
    cache = Directory(p.join(root.path, 'cache'));
    raw = await File(
      'test/fixtures/synthetic.dng',
    ).copy(p.join(root.path, '中文.dng'));
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'RAW previews reuse cache and invalidate it when the source changes',
    () async {
      final decoder = PreviewDecoder();
      final service = PhotoPreviewService(
        cacheDirectory: cache,
        decoder: decoder,
      );
      addTearDown(service.close);
      final before = await hashFile(raw, CancellationToken());
      final first = await service.load(
        PreviewEntry(raw.path),
        CancellationToken(),
      );
      expect(
        (await service.load(PreviewEntry(raw.path), CancellationToken())).path,
        first.path,
      );
      expect(decoder.calls.length, 1);
      expect(await hashFile(raw, CancellationToken()), before);
      await raw.writeAsString('changed source');
      final second = await service.load(
        PreviewEntry(raw.path),
        CancellationToken(),
      );
      expect(second.path, isNot(first.path));
      expect(decoder.calls.length, 2);
    },
  );

  test(
    'ordinary pictures are read directly without conversion or disk cache',
    () async {
      final decoder = PreviewDecoder();
      final service = PhotoPreviewService(
        cacheDirectory: cache,
        decoder: decoder,
      );
      addTearDown(service.close);
      final jpg = await File(
        'test/fixtures/preview.jpg',
      ).copy(p.join(root.path, '图片.jpg'));
      expect(
        (await service.load(PreviewEntry(jpg.path), CancellationToken())).path,
        jpg.path,
      );
      expect(decoder.calls, isEmpty);
      expect(await cache.exists(), isFalse);
    },
  );

  test(
    'cache evicts least recently used previews and leaves unrelated files alone',
    () async {
      final size = await File('test/fixtures/preview.jpg').length();
      final service = PhotoPreviewService(
        cacheDirectory: cache,
        decoder: PreviewDecoder(),
        maxCacheBytes: size * 2,
      );
      addTearDown(service.close);
      final first = await service.load(
        PreviewEntry(raw.path),
        CancellationToken(),
      );
      await first.setLastModified(DateTime(2020));
      final other = await raw.copy(p.join(root.path, 'second.nef'));
      final second = await service.load(
        PreviewEntry(other.path),
        CancellationToken(),
      );
      await second.setLastModified(DateTime(2021));
      await service.load(PreviewEntry(raw.path), CancellationToken());
      final thirdRaw = await raw.copy(p.join(root.path, 'third.arw'));
      final third = await service.load(
        PreviewEntry(thirdRaw.path),
        CancellationToken(),
      );
      expect(await first.exists(), isTrue);
      expect(await second.exists(), isFalse);
      expect(await third.exists(), isTrue);
      final keep = await File(
        p.join(cache.path, 'keep.txt'),
      ).writeAsString('user file');
      await service.clearCache();
      expect(await first.exists(), isFalse);
      expect(await keep.readAsString(), 'user file');
      expect(await raw.exists(), isTrue);
    },
  );

  test('foreground preview is processed before waiting thumbnails', () async {
    final started = Completer<void>(), release = Completer<void>();
    final a = await raw.copy(p.join(root.path, 'a.nef'));
    final b = await raw.copy(p.join(root.path, 'b.nef'));
    final c = await raw.copy(p.join(root.path, 'c.nef'));
    final decoder = PreviewDecoder(
      before: (input, _) async {
        if (p.basename(input) == 'a.nef') {
          started.complete();
          await release.future;
        }
      },
    );
    final service = PhotoPreviewService(
      cacheDirectory: cache,
      decoder: decoder,
    );
    addTearDown(service.close);
    final first = service.load(
      PreviewEntry(a.path),
      CancellationToken(),
      thumbnail: true,
    );
    await started.future;
    final second = service.load(
      PreviewEntry(b.path),
      CancellationToken(),
      thumbnail: true,
    );
    final third = service.load(PreviewEntry(c.path), CancellationToken());
    release.complete();
    await Future.wait([first, second, third]);
    expect(decoder.calls, ['a.nef', 'c.nef', 'b.nef']);
  });

  test(
    'closing cancels active and queued work and removes partial previews',
    () async {
      final started = Completer<void>();
      final service = PhotoPreviewService(
        cacheDirectory: cache,
        decoder: PreviewDecoder(
          before: (_, token) async {
            started.complete();
            while (!token.cancelled) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
          },
        ),
      );
      final first = expectLater(
        service.load(PreviewEntry(raw.path), CancellationToken()),
        throwsA(isA<TaskCancelled>()),
      );
      await started.future;
      final second = expectLater(
        service.load(PreviewEntry(raw.path), CancellationToken()),
        throwsA(isA<TaskCancelled>()),
      );
      await service.close();
      await Future.wait([first, second]);
      expect(await cache.list().isEmpty, isTrue);
      expect(await raw.exists(), isTrue);
    },
  );

  test('a failed decode does not poison subsequent preview jobs', () async {
    var fail = true;
    final service = PhotoPreviewService(
      cacheDirectory: cache,
      decoder: PreviewDecoder(
        before: (_, _) async {
          if (fail) {
            fail = false;
            throw const FormatException('bad RAW');
          }
        },
      ),
    );
    addTearDown(service.close);
    await expectLater(
      service.load(PreviewEntry(raw.path), CancellationToken()),
      throwsFormatException,
    );
    expect(
      await (await service.load(
        PreviewEntry(raw.path),
        CancellationToken(),
      )).exists(),
      isTrue,
    );
  });

  test(
    'source changes during decode cannot create a stale cached preview',
    () async {
      final service = PhotoPreviewService(
        cacheDirectory: cache,
        decoder: PreviewDecoder(
          before: (path, _) async {
            await File(path).writeAsString('changed');
          },
        ),
      );
      addTearDown(service.close);
      await expectLater(
        service.load(PreviewEntry(raw.path), CancellationToken()),
        throwsFormatException,
      );
      expect(await cache.list().isEmpty, isTrue);
    },
  );

  test(
    'damaged cached image can be cleared and regenerated without overwriting it',
    () async {
      final service = PhotoPreviewService(
        cacheDirectory: cache,
        decoder: PreviewDecoder(),
      );
      addTearDown(service.close);
      final cached = await service.load(
        PreviewEntry(raw.path),
        CancellationToken(),
      );
      await cached.writeAsString('damaged');
      await expectLater(
        service.load(PreviewEntry(raw.path), CancellationToken()),
        throwsFormatException,
      );
      expect(await cached.readAsString(), 'damaged');
      await service.clearCache();
      expect(
        await (await service.load(
          PreviewEntry(raw.path),
          CancellationToken(),
        )).length(),
        greaterThan(16),
      );
    },
  );

  test(
    'folder browsing includes RAW and pictures but excludes hidden paths and links',
    () async {
      await File(p.join(root.path, 'photo.JPG')).writeAsString('JPEG');
      await Directory(p.join(root.path, '第二天')).create();
      await File(p.join(root.path, '第二天', 'view.png')).writeAsString('PNG');
      await Directory(p.join(root.path, '.hidden')).create();
      await File(
        p.join(root.path, '.hidden', 'hidden.nef'),
      ).writeAsString('RAW');
      await File(p.join(root.path, 'notes.txt')).writeAsString('text');
      if (!Platform.isWindows) {
        await Link(p.join(root.path, 'link.nef')).create(raw.path);
      }
      final entries = await scanPreviewFolder(root.path, CancellationToken());
      expect(entries.map((entry) => entry.title).toSet(), {
        '中文.dng',
        'photo.JPG',
        p.join('第二天', 'view.png'),
      });
    },
  );

  test(
    'matching browser resolves archived RAW after originals are removed and deduplicates candidates',
    () {
      const jpg = PhotoFile(
        path: '/source/a.jpg',
        relativePath: 'a.jpg',
        size: 1,
        modifiedMicros: 1,
      );
      const raw = PhotoFile(
        path: '/raw/a.nef',
        relativePath: 'a.nef',
        size: 2,
        modifiedMicros: 1,
      );
      final plan = MatchPlan(
        jpgRoot: '/source',
        rawRoot: '/raw',
        rawCount: 1,
        items: [
          MatchItem(jpg: jpg, candidates: [raw]),
          MatchItem(jpg: jpg, candidates: [raw]),
        ],
      );
      final entries = matchedPreviews(plan, {
        '/source/a.jpg': '/archive/JPG/a.jpg',
        '/raw/a.nef': '/archive/RAW/a.nef',
      });
      expect(entries.map((entry) => entry.path).toList(), [
        '/archive/JPG/a.jpg',
        '/archive/RAW/a.nef',
      ]);
      expect(entries.last.isRaw, isTrue);
    },
  );

  test('application close waits for preview cancellation', () async {
    final controller = PickerController();
    addTearDown(controller.dispose);
    var called = false;
    controller.closePreviews = () async {
      called = true;
    };
    expect(await controller.prepareToClose(), isTrue);
    expect(called, isTrue);
  });

  final helper = Platform.isMacOS
      ? 'build/raw_converter/shipian_raw_converter'
      : 'build/windows/x64/runner/Release/shipian_raw_converter.exe';
  test(
    'native RAW preview is decodable and keeps rotation without modifying the original',
    () async {
      await File('test/fixtures/rotated.dng').copy(raw.path);
      final before = await hashFile(raw, CancellationToken());
      final service = PhotoPreviewService(
        cacheDirectory: cache,
        decoder: NativeRawDecoder(
          executable: p.absolute(helper),
          preview: true,
        ),
      );
      addTearDown(service.close);
      final preview = await service.load(
        PreviewEntry(raw.path),
        CancellationToken(),
      );
      final codec = await ui.instantiateImageCodec(await preview.readAsBytes());
      final frame = await codec.getNextFrame();
      expect([frame.image.width, frame.image.height], [192, 256]);
      frame.image.dispose();
      codec.dispose();
      expect(await hashFile(raw, CancellationToken()), before);
    },
    skip: !File(helper).existsSync()
        ? 'Build the native converter first.'
        : false,
  );

  testWidgets(
    'large viewer supports arrows, zoom, fit, and escape at minimum size',
    (tester) async {
      tester.view.physicalSize = const Size(980, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = PhotoPreviewService();
      await tester.pumpWidget(
        MaterialApp(
          theme: Palette.theme,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showPhotoViewer(
                  context,
                  service: service,
                  entries: const [
                    PreviewEntry('/missing/a.jpg'),
                    PreviewEntry('/missing/b.png'),
                  ],
                ),
                child: const Text('大图'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('大图'));
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      final image = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      await tester.tap(find.byTooltip('放大'));
      await tester.pump();
      expect(
        image.transformationController!.value.getMaxScaleOnAxis(),
        greaterThan(1),
      );
      await tester.tap(find.text('适应'));
      await tester.pump();
      expect(image.transformationController!.value.getMaxScaleOnAxis(), 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.runAsync(service.close);
    },
  );

  testWidgets('RAW candidate preview does not change the match selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(980, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const jpg = PhotoFile(
      path: '/missing/a.jpg',
      relativePath: 'a.jpg',
      size: 1,
      modifiedMicros: 1,
    );
    const raw = PhotoFile(
      path: '/raw/a.nef',
      relativePath: 'a.nef',
      size: 2,
      modifiedMicros: 1,
    );
    const other = PhotoFile(
      path: '/raw/b.nef',
      relativePath: 'b.nef',
      size: 2,
      modifiedMicros: 1,
    );
    final service = PhotoPreviewService();
    String? preview, choice;
    await tester.pumpWidget(
      MaterialApp(
        theme: Palette.theme,
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: PreviewPane(
              plan: MatchPlan(
                jpgRoot: '/missing',
                rawRoot: '/raw',
                rawCount: 2,
                items: [
                  MatchItem(jpg: jpg, candidates: [raw, other]),
                ],
              ),
              index: 0,
              busy: false,
              service: service,
              archivedRaws: const {'/raw/a.nef': '/archive/RAW/a.nef'},
              onExpand: (path) => preview = path,
              onChoose: (path) => choice = path,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('预览 RAW').first);
    await tester.pump();
    expect(preview, '/archive/RAW/a.nef');
    expect(choice, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(service.close);
  });
}
