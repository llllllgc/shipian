import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:raw_jpg_picker/core/cleanup.dart';
import 'package:raw_jpg_picker/core/exporter.dart';
import 'package:raw_jpg_picker/core/matcher.dart';
import 'package:raw_jpg_picker/core/models.dart';

void main() {
  late Directory fixture;
  late String jpg, raw, output;
  Future<File> file(String root, String path, String content) async {
    final result = File(p.join(root, path));
    await result.parent.create(recursive: true);
    return result.writeAsString(content);
  }

  Future<MatchPlan> scan() => PhotoMatcher().scan(
    jpgRoot: jpg,
    rawRoot: raw,
    token: CancellationToken(),
  );
  Future<ExportResult> archive(MatchPlan plan) => RawExporter().export(
    plan: plan,
    outputRoot: output,
    includeJpg: true,
    token: CancellationToken(),
  );
  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('raw_cleanup_test_');
    jpg = p.join(fixture.path, 'JPG');
    raw = p.join(fixture.path, 'RAW');
    output = p.join(fixture.path, 'OUT');
    for (final dir in [jpg, raw, output]) {
      await Directory(dir).create();
    }
    await file(jpg, 'DSC_1.jpg', 'JPG content');
    await file(raw, 'Day1/DSC_1.NEF', 'RAW content');
  });
  tearDown(() async {
    await fixture.delete(recursive: true);
  });

  test(
    'pair archive requires hashes and preserves originals until cleanup is explicitly called',
    () async {
      final plan = await scan();
      final result = await archive(plan);
      expect(result.copiedJpg, ['DSC_1.jpg']);
      expect(result.receipts.length, 2);
      expect(result.receipts.every((r) => r.sha256.length == 64), isTrue);
      expect(await File(p.join(jpg, 'DSC_1.jpg')).exists(), isTrue);
      expect(await File(p.join(raw, 'Day1/DSC_1.NEF')).exists(), isTrue);
      expect(
        await File(p.join(result.directory, 'JPG/DSC_1.jpg')).readAsString(),
        'JPG content',
      );
    },
  );
  test(
    'confirmed cleanup removes only archived RAW and its imported source JPG',
    () async {
      await file(raw, 'UNSELECTED.NEF', 'keep raw');
      await file(jpg, 'MISSING.jpg', 'keep jpg');
      final plan = await scan(), result = await archive(await scan());
      final preview = SourceCleanup().preview(plan, result);
      expect(preview.rawCount, 1);
      expect(preview.jpgCount, 1);
      final clean = await SourceCleanup().clean(
        plan: plan,
        archive: result,
        token: CancellationToken(),
      );
      expect(clean.deleted.length, 2);
      expect(clean.failures, isEmpty);
      expect(clean.error, isNull);
      expect(await File(p.join(raw, 'Day1/DSC_1.NEF')).exists(), isFalse);
      expect(await File(p.join(jpg, 'DSC_1.jpg')).exists(), isFalse);
      expect(
        await File(p.join(raw, 'UNSELECTED.NEF')).readAsString(),
        'keep raw',
      );
      expect(await File(p.join(jpg, 'MISSING.jpg')).readAsString(), 'keep jpg');
      expect(
        await File(
          p.join(result.directory, 'RAW/Day1/DSC_1.NEF'),
        ).readAsString(),
        'RAW content',
      );
      expect(
        await File(p.join(result.directory, 'JPG/DSC_1.jpg')).readAsString(),
        'JPG content',
      );
      expect(
        SourceCleanup()
            .preview(plan, result, alreadyDeleted: clean.deleted.toSet())
            .targets,
        isEmpty,
      );
    },
  );
  test(
    'changed archived content with identical size and timestamp prevents all source cleanup',
    () async {
      final plan = await scan();
      final result = await archive(plan);
      final target = File(p.join(result.directory, 'RAW/Day1/DSC_1.NEF'));
      final time = await target.lastModified();
      await target.writeAsString('BAD content');
      await target.setLastModified(time);
      final clean = await SourceCleanup().clean(
        plan: plan,
        archive: result,
        token: CancellationToken(),
      );
      expect(clean.deleted, isEmpty);
      expect(clean.failures, isNotEmpty);
      expect(await File(p.join(jpg, 'DSC_1.jpg')).exists(), isTrue);
      expect(await File(p.join(raw, 'Day1/DSC_1.NEF')).exists(), isTrue);
    },
  );
  test(
    'changed source content with preserved metadata also prevents cleanup',
    () async {
      final plan = await scan();
      final result = await archive(plan);
      final original = File(p.join(jpg, 'DSC_1.jpg'));
      final time = await original.lastModified();
      await original.writeAsString('BAD content');
      await original.setLastModified(time);
      final clean = await SourceCleanup().clean(
        plan: plan,
        archive: result,
        token: CancellationToken(),
      );
      expect(clean.deleted, isEmpty);
      expect(clean.failures, isNotEmpty);
      expect(await File(p.join(raw, 'Day1/DSC_1.NEF')).exists(), isTrue);
    },
  );
  test('missing archive or substituted symbolic link blocks cleanup', () async {
    final plan = await scan();
    final result = await archive(plan);
    final target = File(p.join(result.directory, 'JPG/DSC_1.jpg'));
    await target.delete();
    if (!Platform.isWindows) {
      await Link(target.path).create(p.join(jpg, 'DSC_1.jpg'));
    }
    final clean = await SourceCleanup().clean(
      plan: plan,
      archive: result,
      token: CancellationToken(),
    );
    expect(clean.deleted, isEmpty);
    expect(clean.failures, isNotEmpty);
    expect(await File(p.join(jpg, 'DSC_1.jpg')).exists(), isTrue);
  });
  test(
    'a failed JPG archive blocks the entire RAW/JPG group from cleanup',
    () async {
      final plan = await scan();
      await File(p.join(jpg, 'DSC_1.jpg')).writeAsString('changed JPG data');
      final result = await archive(plan);
      expect(result.copied.length, 1);
      expect(result.copiedJpg, isEmpty);
      final preview = SourceCleanup().preview(plan, result);
      expect(preview.targets, isEmpty);
      expect(preview.blockedGroups, 1);
      expect(await File(p.join(raw, 'Day1/DSC_1.NEF')).exists(), isTrue);
    },
  );
  test(
    'several selected JPGs for one RAW archive all JPGs and clean the RAW once',
    () async {
      await file(jpg, 'Other/DSC_1.jpg', 'another JPG');
      final plan = await scan();
      final result = await archive(plan);
      expect(result.copied.length, 1);
      expect(result.copiedJpg.length, 2);
      final preview = SourceCleanup().preview(plan, result);
      expect(preview.targets.length, 3);
      expect(preview.rawCount, 1);
    },
  );
  test('cancel before or during validation never deletes originals', () async {
    final plan = await scan();
    final result = await archive(plan);
    final token = CancellationToken();
    final clean = await SourceCleanup().clean(
      plan: plan,
      archive: result,
      token: token,
      onProgress: (_) {
        token.cancelled = true;
      },
    );
    expect(clean.cancelled, isTrue);
    expect(clean.deleted, isEmpty);
    expect(await File(p.join(jpg, 'DSC_1.jpg')).exists(), isTrue);
    expect(await File(p.join(raw, 'Day1/DSC_1.NEF')).exists(), isTrue);
  });
  test('continuing an interrupted task reuses one archive directory', () async {
    final plan = await scan();
    final token = CancellationToken();
    final first = await RawExporter().export(
      plan: plan,
      outputRoot: output,
      includeJpg: true,
      token: token,
      onProgress: (value) {
        if (value.completed == 1) token.cancelled = true;
      },
    );
    expect(first.cancelled, isTrue);
    final second = await RawExporter().export(
      plan: plan,
      outputRoot: output,
      includeJpg: true,
      token: CancellationToken(),
      resume: first,
    );
    expect(second.directory, first.directory);
    expect(second.complete, isTrue);
    expect(second.receipts.length, 2);
    expect(await Directory(output).list().length, 1);
  });
  test(
    'raw-only backup is never offered as sufficient evidence to delete source JPGs',
    () async {
      final plan = await scan();
      final result = await RawExporter().export(
        plan: plan,
        outputRoot: output,
        token: CancellationToken(),
        verifyHash: true,
      );
      expect(SourceCleanup().preview(plan, result).targets, isEmpty);
    },
  );
  test(
    'interrupted cleanup can continue without deleting an original twice',
    () async {
      final plan = await scan();
      final result = await archive(plan);
      final token = CancellationToken();
      final first = await SourceCleanup().clean(
        plan: plan,
        archive: result,
        token: token,
        onProgress: (value) {
          if (!value.verifying && value.completed == 1) token.cancelled = true;
        },
      );
      expect(first.deleted.length, 1);
      expect(first.cancelled, isTrue);
      final second = await SourceCleanup().clean(
        plan: plan,
        archive: result,
        token: CancellationToken(),
        alreadyDeleted: first.deleted.toSet(),
      );
      expect(second.deleted.length, 1);
      expect(second.failures, isEmpty);
      expect({...first.deleted, ...second.deleted}.length, 2);
      expect(await Directory(output).list().length, 1);
    },
  );
}
