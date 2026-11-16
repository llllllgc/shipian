import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:raw_jpg_picker/core/atomic_commit.dart';
import 'package:raw_jpg_picker/core/exporter.dart';
import 'package:raw_jpg_picker/core/matcher.dart';
import 'package:raw_jpg_picker/core/models.dart';

void main() {
  late Directory fixture;
  late String jpg, raw, output;
  Future<File> file(
    String root,
    String relative, [
    String text = 'photo sample',
  ]) async {
    final result = File(p.join(root, relative));
    await result.parent.create(recursive: true);
    return result.writeAsString(text);
  }

  Future<MatchPlan> scan() => PhotoMatcher().scan(
    jpgRoot: jpg,
    rawRoot: raw,
    token: CancellationToken(),
  );
  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('raw_picker_test_');
    jpg = p.join(fixture.path, '已选 JPG');
    raw = p.join(fixture.path, '全部 RAW');
    output = p.join(fixture.path, '导出');
    for (final path in [jpg, raw, output]) {
      await Directory(path).create();
    }
  });
  tearDown(() async {
    await fixture.delete(recursive: true);
  });

  test(
    'recursive matching handles case, Unicode normalization, and RAW formats',
    () async {
      await file(jpg, '入选/DSC_0123.JPG');
      await file(raw, '旅行/dsc_0123.NEF');
      await file(jpg, 'Cafe\u0301.jpeg');
      await file(raw, 'Café.ARW');
      final plan = await scan();
      expect(plan.rawCount, 2);
      expect(plan.count(MatchStatus.matched), 2);
      expect(plan.totalBytes, 24);
    },
  );
  test(
    'duplicates are deduplicated; conflicts need explicit selection',
    () async {
      await file(jpg, 'A/DSC_0001.jpg');
      await file(jpg, 'B/DSC_0001.jpg');
      await file(raw, 'DSC_0001.NEF');
      var plan = await scan();
      expect(plan.items.length, 2);
      expect(plan.selected.length, 1);
      await file(raw, '第二天/DSC_0001.NEF');
      plan = await scan();
      expect(plan.count(MatchStatus.conflict), 2);
      expect(plan.selected, isEmpty);
      expect(() => plan.choose(0, 'not a candidate'), throwsArgumentError);
      plan = plan.choose(0, plan.items[0].candidates.last.path);
      expect(plan.items[0].manuallyChosen, isTrue);
      expect(plan.selected.length, 1);
      expect(plan.choose(0, null).selected, isEmpty);
    },
  );
  test(
    'missing and renamed JPGs are not guessed; dot directories are ignored',
    () async {
      await file(jpg, 'DSC_0001_修图.jpg');
      await file(raw, 'DSC_0001.NEF');
      await file(jpg, '.hidden/DSC_0002.jpg');
      await file(raw, '.hidden/DSC_0001_修图.NEF');
      final plan = await scan();
      expect(plan.items.length, 1);
      expect(plan.rawCount, 1);
      expect(plan.count(MatchStatus.missing), 1);
    },
  );
  test(
    'symbolic links cannot introduce a hidden duplicate',
    () async {
      await file(jpg, 'DSC.jpg');
      await file(raw, 'DSC.NEF');
      await Link(p.join(raw, 'DSC.ARW')).create(p.join(raw, 'DSC.NEF'));
      final plan = await scan();
      expect(plan.rawCount, 1);
      expect(plan.count(MatchStatus.matched), 1);
    },
    skip: Platform.isWindows
        ? 'Windows symlinks require additional privileges'
        : false,
  );
  test('empty JPG sources and invalid directories stop the scan', () async {
    await expectLater(scan(), throwsFormatException);
    await expectLater(
      PhotoMatcher().scan(
        jpgRoot: '$jpg/missing',
        rawRoot: raw,
        token: CancellationToken(),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
  test(
    'export preserves subdirectories, deduplicates, verifies and writes truthful reports',
    () async {
      await file(jpg, 'A/DSC_0001.jpg');
      await file(jpg, 'B/DSC_0001.jpg');
      final original = await file(raw, '旅行/DSC_0001.NEF', 'original RAW bytes');
      await file(jpg, 'MISSING.jpg');
      final plan = await scan();
      final result = await RawExporter().export(
        plan: plan,
        outputRoot: output,
        token: CancellationToken(),
        verifyHash: true,
      );
      expect(result.complete, isTrue);
      expect(result.copied, [p.join('旅行', 'DSC_0001.NEF')]);
      final copy = File(p.join(result.directory, 'RAW', '旅行', 'DSC_0001.NEF'));
      expect(await copy.readAsBytes(), await original.readAsBytes());
      expect(await original.exists(), isTrue);
      final report = jsonDecode(
        await File(p.join(result.directory, '处理记录.json')).readAsString(),
      );
      expect(report['selectedCount'], 1);
      expect(report['verification'], 'SHA-256');
      final csv = await File(
        p.join(result.directory, '匹配清单.csv'),
      ).readAsString();
      final csvBytes = await File(
        p.join(result.directory, '匹配清单.csv'),
      ).readAsBytes();
      expect(csvBytes.take(3), [0xef, 0xbb, 0xbf]);
      expect(csv, contains('未找到 RAW'));
      expect(csv, contains('跳过'));
      final second = await RawExporter().export(
        plan: plan,
        outputRoot: output,
        token: CancellationToken(),
      );
      expect(second.directory, isNot(result.directory));
    },
  );
  test(
    'output inside a source is rejected before creating any result',
    () async {
      await file(jpg, 'DSC.jpg');
      await file(raw, 'DSC.NEF');
      final plan = await scan();
      await expectLater(
        RawExporter().export(
          plan: plan,
          outputRoot: raw,
          token: CancellationToken(),
        ),
        throwsFormatException,
      );
      expect(await Directory(raw).list().length, 1);
    },
  );
  test('changed source files fail safely and remain untouched', () async {
    await file(jpg, 'DSC.jpg');
    final original = await file(raw, 'DSC.NEF');
    final plan = await scan();
    await original.writeAsString('changed after scan - longer content');
    final result = await RawExporter().export(
      plan: plan,
      outputRoot: output,
      token: CancellationToken(),
    );
    expect(result.copied, isEmpty);
    expect(result.failures, hasLength(1));
    expect(
      await original.readAsString(),
      'changed after scan - longer content',
    );
    expect(
      await File(p.join(result.directory, 'RAW', 'DSC.NEF')).exists(),
      isFalse,
    );
  });
  test(
    'cancellation removes the unfinished file and records cancellation',
    () async {
      await file(jpg, 'DSC.jpg');
      await file(raw, 'DSC.NEF', 'x' * 200000);
      final plan = await scan();
      final token = CancellationToken();
      final result = await RawExporter().export(
        plan: plan,
        outputRoot: output,
        token: token,
        onProgress: (_) {
          token.cancelled = true;
        },
      );
      expect(result.cancelled, isTrue);
      expect(result.copied, isEmpty);
      expect(
        await Directory(result.directory)
            .list(recursive: true)
            .where(
              (e) => e.path.endsWith('.partial') || e.path.endsWith('.NEF'),
            )
            .length,
        0,
      );
      expect(await File(p.join(raw, 'DSC.NEF')).length(), 200000);
    },
  );
  test('a destination appearing during copy is never replaced', () async {
    await file(jpg, 'DSC.jpg');
    await file(raw, 'DSC.NEF', 'x' * 200000);
    final plan = await scan();
    var created = false;
    late File existing;
    final result = await RawExporter().export(
      plan: plan,
      outputRoot: output,
      token: CancellationToken(),
      onProgress: (_) {
        if (created) return;
        final batch = Directory(
          output,
        ).listSync().whereType<Directory>().single;
        existing = File(p.join(batch.path, 'RAW', 'DSC.NEF'));
        existing.writeAsStringSync('existing file - protect me');
        created = true;
      },
    );
    expect(result.copied, isEmpty);
    expect(result.failures, hasLength(1));
    expect(await existing.readAsString(), 'existing file - protect me');
    expect(await File('${existing.path}.partial').exists(), isFalse);
  });
  test(
    'OS commit rejects existing files and succeeds with a new destination',
    () async {
      final source = await file(output, 'photo.partial', 'new data');
      final existing = await file(output, 'photo.NEF', 'existing data');
      expect(
        () => commitWithoutReplacing(source.path, existing.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await existing.readAsString(), 'existing data');
      final target = p.join(output, 'new.NEF');
      commitWithoutReplacing(source.path, target);
      expect(await source.exists(), isFalse);
      expect(await File(target).readAsString(), 'new data');
    },
  );
  test('CSV file names starting with formula characters are escaped', () async {
    await file(jpg, '=FORMULA.jpg');
    final plan = await scan();
    final result = await RawExporter().export(
      plan: plan,
      outputRoot: output,
      token: CancellationToken(),
    );
    final csv = await File(p.join(result.directory, '匹配清单.csv')).readAsString();
    expect(csv, contains("'=FORMULA.jpg"));
    expect(result.total, 0);
  });
}
