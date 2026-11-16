import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:raw_jpg_picker/app_controller.dart';
import 'package:raw_jpg_picker/core/converter.dart';
import 'package:raw_jpg_picker/core/integrity.dart';
import 'package:raw_jpg_picker/core/models.dart';

class FixtureDecoder implements RawDecoder {
  FixtureDecoder({this.beforeWrite});
  final Future<void> Function(String, CancellationToken)? beforeWrite;
  int calls = 0;
  @override
  Future<void> decode({
    required String input,
    required String output,
    required ImageFormat format,
    required int quality,
    required CancellationToken token,
  }) async {
    calls++;
    await beforeWrite?.call(input, token);
    token.check();
    await File(output).writeAsBytes(
      format == ImageFormat.jpg
          ? [255, 216, ...List.filled(20, quality), 255, 217]
          : [137, 80, 78, 71, 13, 10, 26, 10, ...List.filled(20, 0)],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary, input, output;
  setUp(() async {
    temporary = Directory(
      await (await Directory.systemTemp.createTemp(
        'shipian_convert_',
      )).resolveSymbolicLinks(),
    );
    input = await Directory(p.join(temporary.path, '来源')).create();
    output = await Directory(p.join(temporary.path, '输出')).create();
    await File(
      'test/fixtures/synthetic.dng',
    ).copy(p.join(input.path, '中文照片.dng'));
  });
  tearDown(() => temporary.delete(recursive: true));

  ConversionRequest request({
    ImageFormat format = ImageFormat.jpg,
    int quality = 90,
  }) => ConversionRequest(
    inputRoot: input.path,
    outputRoot: output.path,
    format: format,
    quality: quality,
  );

  test(
    'repeat conversion verifies and reuses the same output without duplicates',
    () async {
      final decoder = FixtureDecoder();
      final converter = RawImageConverter(decoder: decoder);
      final raw = File(p.join(input.path, '中文照片.dng'));
      final originalHash = await hashFile(raw, CancellationToken());
      final first = await converter.convert(
        request: request(),
        token: CancellationToken(),
      );
      final image = File(p.join(first.directory, first.converted.single));
      final modified = (await image.stat()).modified;
      final second = await converter.convert(
        request: request(),
        token: CancellationToken(),
      );
      expect(second.directory, first.directory);
      expect(second.converted, isEmpty);
      expect(second.reused, ['中文照片.jpg']);
      expect(decoder.calls, 1);
      expect((await image.stat()).modified, modified);
      expect(await hashFile(raw, CancellationToken()), originalHash);
    },
  );

  test(
    'user files and changed conversion outputs are never overwritten',
    () async {
      final decoder = FixtureDecoder();
      final converter = RawImageConverter(decoder: decoder);
      final first = await converter.convert(
        request: request(),
        token: CancellationToken(),
      );
      final image = File(p.join(first.directory, first.converted.single));
      await image.writeAsString('user changed image');
      final second = await converter.convert(
        request: request(),
        token: CancellationToken(),
      );
      expect(second.failures.length, 1);
      expect(decoder.calls, 1);
      expect(await image.readAsString(), 'user changed image');
      await File(p.join(input.path, 'another.nef')).writeAsString('RAW');
      final other = File(p.join(first.directory, 'another.jpg'));
      await other.writeAsString('existing JPG');
      final third = await converter.convert(
        request: request(),
        token: CancellationToken(),
      );
      expect(third.failures.length, 2);
      expect(await other.readAsString(), 'existing JPG');
    },
  );

  test(
    'same stem RAW formats keep separate output names and relative folders',
    () async {
      await File(p.join(input.path, '中文照片.nef')).writeAsString('RAW');
      await Directory(p.join(input.path, '第二天')).create();
      await File(p.join(input.path, '第二天', '中文照片.dng')).writeAsString('RAW');
      final result = await RawImageConverter(
        decoder: FixtureDecoder(),
      ).convert(request: request(), token: CancellationToken());
      expect(result.failures, isEmpty);
      expect(result.converted.toSet(), {
        '中文照片.dng.jpg',
        '中文照片.nef.jpg',
        p.join('第二天', '中文照片.jpg'),
      });
    },
  );

  test(
    'cancellation removes staging files and a retry completes the same directory',
    () async {
      final token = CancellationToken();
      final result = await RawImageConverter(
        decoder: FixtureDecoder(
          beforeWrite: (_, token) async {
            token.cancelled = true;
          },
        ),
      ).convert(request: request(), token: token);
      expect(result.cancelled, isTrue);
      expect(result.converted, isEmpty);
      expect(
        (await Directory(
          result.directory,
        ).list().toList()).whereType<Directory>(),
        isEmpty,
      );
      final retry = await RawImageConverter(
        decoder: FixtureDecoder(),
      ).convert(request: request(), token: CancellationToken());
      expect(retry.directory, result.directory);
      expect(retry.converted.length, 1);
    },
  );

  test('changed source during conversion is rejected before commit', () async {
    final result = await RawImageConverter(
      decoder: FixtureDecoder(
        beforeWrite: (source, _) async {
          await File(source).writeAsString('changed');
        },
      ),
    ).convert(request: request(), token: CancellationToken());
    expect(result.converted, isEmpty);
    expect(result.failures.length, 1);
    expect(await File(p.join(result.directory, '中文照片.jpg')).exists(), isFalse);
  });

  test(
    'one unsupported RAW fails independently while the rest complete',
    () async {
      await File(p.join(input.path, 'broken.nef')).writeAsString('bad RAW');
      final result = await RawImageConverter(
        decoder: FixtureDecoder(
          beforeWrite: (source, _) async {
            if (source.endsWith('broken.nef')) {
              throw const FormatException('unsupported');
            }
          },
        ),
      ).convert(request: request(), token: CancellationToken());
      expect(result.converted, ['中文照片.jpg']);
      expect(result.failures, {'broken.nef': 'unsupported'});
    },
  );

  test(
    'crash recovery reuses committed image and removes only its recorded partial',
    () async {
      final decoder = FixtureDecoder();
      final converter = RawImageConverter(decoder: decoder);
      final first = await converter.convert(
        request: request(),
        token: CancellationToken(),
      );
      final orphan = await Directory(
        p.join(first.directory, '.shipian-convert-recovery'),
      ).create();
      await File(p.join(orphan.path, 'image.partial')).writeAsString('partial');
      final untouched = await File(
        p.join(first.directory, 'my.partial'),
      ).writeAsString('user');
      final log = File(p.join(first.directory, '.拾片转换记录.jsonl'));
      await log.writeAsString(
        '${jsonEncode({'event': 'prepare', 'temporary': p.basename(orphan.path)})}\n{"event":',
        mode: FileMode.append,
      );
      final recovered = await converter.convert(
        request: request(),
        token: CancellationToken(),
      );
      final again = await converter.convert(
        request: request(),
        token: CancellationToken(),
      );
      expect(recovered.reused.length, 1);
      expect(again.reused.length, 1);
      expect(await orphan.exists(), isFalse);
      expect(await untouched.readAsString(), 'user');
      expect(decoder.calls, 1);
    },
  );

  test(
    'PNG reuses output independently of hidden JPEG quality setting',
    () async {
      final converter = RawImageConverter(decoder: FixtureDecoder());
      final first = await converter.convert(
        request: request(format: ImageFormat.png, quality: 80),
        token: CancellationToken(),
      );
      final again = await converter.convert(
        request: request(format: ImageFormat.png, quality: 100),
        token: CancellationToken(),
      );
      expect(first.converted.length, 1);
      expect(again.reused.length, 1);
    },
  );

  test(
    'converted images do not authorize source cleanup; archived RAW works after cleanup',
    () async {
      final jpg = await Directory(p.join(temporary.path, '已选')).create();
      await File(p.join(jpg.path, '中文照片.jpg')).writeAsString('selected JPG');
      final controller = PickerController()
        ..setSource(jpg: jpg.path, raw: input.path)
        ..setOutput(output.path);
      addTearDown(controller.dispose);
      await controller.scan();
      await controller.convertImages(
        request(),
        selectedOnly: true,
        decoder: FixtureDecoder(),
      );
      expect(controller.conversion!.completed, 1);
      expect(controller.canClean, isFalse);
      await controller.export();
      await controller.cleanSources();
      expect(await File(p.join(input.path, '中文照片.dng')).exists(), isFalse);
      await controller.convertImages(
        ConversionRequest(
          outputRoot: controller.result!.directory,
          format: ImageFormat.png,
        ),
        selectedOnly: true,
        decoder: FixtureDecoder(),
      );
      expect(controller.error, isNull);
      expect(controller.conversion!.completed, 1);
      expect(controller.conversion!.failures, isEmpty);
      final archivedRaw = File(
        p.join(controller.result!.directory, 'RAW', '中文照片.dng'),
      );
      await archivedRaw.writeAsString('tampered archive');
      await controller.convertImages(
        request(),
        selectedOnly: true,
        decoder: FixtureDecoder(),
      );
      expect(controller.conversion!.failures.length, 1);
    },
  );

  test(
    'close cancels an active conversion and waits for staging cleanup',
    () async {
      final started = Completer<void>();
      final controller = PickerController();
      addTearDown(controller.dispose);
      final operation = controller.convertImages(
        request(),
        decoder: FixtureDecoder(
          beforeWrite: (_, token) async {
            started.complete();
            while (!token.cancelled) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          },
        ),
      );
      await started.future;
      expect(controller.busy, isTrue);
      expect(await controller.prepareToClose(), isTrue);
      await operation;
      expect(controller.busy, isFalse);
      expect(controller.conversion!.cancelled, isTrue);
    },
  );

  test('output directory links cannot redirect conversion writes', () async {
    if (Platform.isWindows) return; // Windows link privileges vary by runner.
    final elsewhere = await Directory(p.join(temporary.path, '别处')).create();
    await Link(p.join(output.path, 'RAW转图片')).create(elsewhere.path);
    await expectLater(
      RawImageConverter(
        decoder: FixtureDecoder(),
      ).convert(request: request(), token: CancellationToken()),
      throwsA(isA<FileSystemException>()),
    );
    expect(await elsewhere.list().isEmpty, isTrue);
  });

  final helper = Platform.isMacOS
      ? 'build/raw_converter/shipian_raw_converter'
      : 'build/windows/x64/runner/Release/shipian_raw_converter.exe';
  test(
    'native decoder rejects invalid RAW without publishing an image',
    () async {
      await File(
        p.join(input.path, '中文照片.dng'),
      ).writeAsString('this is not RAW data');
      final result = await RawImageConverter(
        decoder: NativeRawDecoder(executable: p.absolute(helper)),
      ).convert(request: request(), token: CancellationToken());
      expect(result.converted, isEmpty);
      expect(result.failures.length, 1);
      expect(
        await File(p.join(result.directory, '中文照片.jpg')).exists(),
        isFalse,
      );
    },
    skip: !File(helper).existsSync()
        ? 'Build the native converter first.'
        : false,
  );

  test(
    'cancelling the native decoder terminates its subprocess promptly',
    () async {
      final script = await File(
        p.join(temporary.path, 'slow-decoder'),
      ).writeAsString('#!/bin/sh\nexec /bin/sleep 60\n');
      await Process.run('/bin/chmod', ['+x', script.path]);
      final token = CancellationToken();
      final timer = Timer(
        const Duration(milliseconds: 100),
        () => token.cancelled = true,
      );
      final watch = Stopwatch()..start();
      try {
        await expectLater(
          NativeRawDecoder(executable: script.path).decode(
            input: p.join(input.path, '中文照片.dng'),
            output: p.join(output.path, 'test.jpg'),
            format: ImageFormat.jpg,
            quality: 90,
            token: token,
          ),
          throwsA(isA<TaskCancelled>()),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      } finally {
        timer.cancel();
      }
    },
    skip: Platform.isWindows,
  );
  for (final format in ImageFormat.values) {
    test(
      'native LibRaw produces a decodable full-size ${format.name} with Chinese paths',
      () async {
        final raw = File(p.join(input.path, '中文照片.dng'));
        final before = await hashFile(raw, CancellationToken());
        final converter = RawImageConverter(
          decoder: NativeRawDecoder(executable: p.absolute(helper)),
        );
        final result = await converter.convert(
          request: request(format: format),
          token: CancellationToken(),
        );
        expect(result.failures, isEmpty);
        final image = await ui.instantiateImageCodec(
          await File(
            p.join(result.directory, result.converted.single),
          ).readAsBytes(),
        );
        final frame = await image.getNextFrame();
        expect(frame.image.width, 256);
        expect(frame.image.height, 192);
        frame.image.dispose();
        image.dispose();
        expect(await hashFile(raw, CancellationToken()), before);
      },
      skip: !File(helper).existsSync()
          ? 'Build the native converter first.'
          : false,
    );
  }
  test(
    'native RAW orientation is applied to pixels',
    () async {
      await File(
        'test/fixtures/rotated.dng',
      ).copy(p.join(input.path, '中文照片.dng'));
      final result = await RawImageConverter(
        decoder: NativeRawDecoder(executable: p.absolute(helper)),
      ).convert(request: request(), token: CancellationToken());
      expect(result.failures, isEmpty);
      final codec = await ui.instantiateImageCodec(
        await File(
          p.join(result.directory, result.converted.single),
        ).readAsBytes(),
      );
      final frame = await codec.getNextFrame();
      expect([frame.image.width, frame.image.height], [192, 256]);
      frame.image.dispose();
      codec.dispose();
    },
    skip: !File(helper).existsSync()
        ? 'Build the native converter first.'
        : false,
  );
}
