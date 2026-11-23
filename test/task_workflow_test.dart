import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:raw_jpg_picker/app_controller.dart';
import 'package:raw_jpg_picker/core/exporter.dart';
import 'package:raw_jpg_picker/core/archive_import.dart';
import 'package:raw_jpg_picker/core/models.dart';
import 'package:raw_jpg_picker/core/restorer.dart';
import 'package:raw_jpg_picker/core/task_recovery.dart';
import 'package:raw_jpg_picker/core/task_snapshot.dart';
import 'package:raw_jpg_picker/core/task_store.dart';

void main() {
  late Directory fixture;
  late String jpg, raw, output;
  late TaskStore store;
  final controllers = <PickerController>[];
  Future<File> file(String root, String relative, String content) async {
    final f = File(p.join(root, relative));
    await f.parent.create(recursive: true);
    return f.writeAsString(content);
  }

  PickerController controller() {
    final c = PickerController(store: store);
    controllers.add(c);
    return c;
  }

  Future<PickerController> started() async {
    final c = controller()
      ..setSource(jpg: jpg, raw: raw)
      ..setOutput(output);
    await c.scan();
    expect(c.error, isNull);
    return c;
  }

  Future<PickerController> restart(PickerController c) async {
    expect(await c.prepareToClose(), isTrue);
    c.dispose();
    controllers.remove(c);
    final next = controller();
    await next.initialize();
    expect(next.error, isNull);
    return next;
  }

  setUp(() async {
    fixture = Directory(
      await (await Directory.systemTemp.createTemp(
        'shipian_tasks_',
      )).resolveSymbolicLinks(),
    );
    jpg = p.join(fixture.path, 'JPG');
    raw = p.join(fixture.path, 'RAW');
    output = p.join(fixture.path, 'OUT');
    for (final root in [jpg, raw, output]) {
      await Directory(root).create();
    }
    store = TaskStore(Directory(p.join(fixture.path, 'tasks')));
    await file(jpg, 'DSC_1.jpg', 'original JPG');
    await file(raw, 'Day1/DSC_1.NEF', 'original RAW');
  });
  tearDown(() async {
    for (final c in controllers) {
      await c.prepareToClose();
      c.dispose();
    }
    controllers.clear();
    await fixture.delete(recursive: true);
  });

  test(
    'restart restores manual choice, selected row, filters and search without performing an operation',
    () async {
      await file(raw, 'Day2/DSC_1.NEF', 'another RAW');
      var c = await started();
      c.choose(0, p.join(raw, 'Day2', 'DSC_1.NEF'));
      c.updateView(selected: 0, status: '已匹配', search: 'DSC_1');
      final id = c.currentTaskId;
      c = await restart(c);
      expect(c.currentTaskId, id);
      expect(c.plan!.items.single.raw!.path, p.join(raw, 'Day2', 'DSC_1.NEF'));
      expect(c.filter, '已匹配');
      expect(c.query, 'DSC_1');
      expect(c.selectedIndex, 0);
      expect(c.result, isNull);
      expect(await Directory(output).list().length, 0);
    },
  );

  test(
    'completed archive stays complete after restart and unchanged refresh does not make another folder',
    () async {
      var c = await started();
      await c.export();
      expect(c.error, isNull);
      final path = c.result!.directory;
      c = await restart(c);
      expect(c.result!.directory, path);
      expect(c.canExport, isFalse);
      await c.scan();
      expect(c.canExport, isFalse);
      await c.export();
      expect(await Directory(output).list().length, 1);
    },
  );

  test(
    'incremental archive reuses existing files and directory and copies only new JPG/RAW',
    () async {
      var c = await started();
      await c.export();
      final directory = c.result!.directory;
      final originalCopy = File(p.join(directory, 'RAW/Day1/DSC_1.NEF'));
      final sentinel = DateTime(2020, 1, 2);
      await originalCopy.setLastModified(sentinel);
      c = await restart(c);
      await file(jpg, 'DSC_2.jpg', 'new JPG');
      await file(raw, 'Day2/DSC_2.NEF', 'new RAW');
      await c.scan();
      expect(c.canExport, isTrue);
      await c.export();
      expect(c.error, isNull);
      expect(c.result!.directory, directory);
      expect(c.result!.receipts.length, 4);
      expect(await originalCopy.lastModified(), sentinel);
      expect(await Directory(output).list().length, 1);
      expect(
        await File(p.join(directory, 'JPG/DSC_2.jpg')).readAsString(),
        'new JPG',
      );
    },
  );

  test(
    'new files can join a task whose old source pairs have already been cleaned',
    () async {
      var c = await started();
      await c.export();
      await c.cleanSources();
      expect(c.error, isNull);
      final directory = c.result!.directory;
      c = await restart(c);
      await file(jpg, 'DSC_2.jpg', 'new JPG');
      await file(raw, 'Day2/DSC_2.NEF', 'new RAW');
      await c.scan();
      expect(c.plan!.items.length, 2);
      await c.export();
      expect(c.error, isNull);
      expect(c.result!.directory, directory);
      expect(c.result!.copied.length, 2);
      expect(c.result!.copiedJpg.length, 2);
      expect(c.cleanupPreview.targets.length, 2);
      expect(await Directory(output).list().length, 1);
    },
  );

  test(
    'cleaned originals can be restored after restart and the archive is retained',
    () async {
      var c = await started();
      await c.export();
      await c.cleanSources();
      c = await restart(c);
      expect(c.canRestore, isTrue);
      final preview = await c.prepareRestore();
      expect(preview.targets.length, 2);
      expect(preview.conflicts, isEmpty);
      await c.restoreSources({});
      expect(c.error, isNull);
      expect(c.restoration!.failures, isEmpty);
      expect(
        await File(p.join(jpg, 'DSC_1.jpg')).readAsString(),
        'original JPG',
      );
      expect(
        await File(p.join(raw, 'Day1', 'DSC_1.NEF')).readAsString(),
        'original RAW',
      );
      expect(
        await File(p.join(c.result!.directory, 'JPG/DSC_1.jpg')).exists(),
        isTrue,
      );
      c = await restart(c);
      expect(c.canRestore, isFalse);
      expect(c.removedSources, isEmpty);
    },
  );

  test(
    'restore conflicts are skipped by default and keep-both generates a non-overwriting name',
    () async {
      final c = await started();
      await c.export();
      await c.cleanSources();
      await file(jpg, 'DSC_1.jpg', 'new user content');
      final preview = await c.prepareRestore();
      expect(preview.conflicts.length, 1);
      await c.restoreSources({});
      expect(c.restoration!.skipped, [p.join(jpg, 'DSC_1.jpg')]);
      expect(
        await File(p.join(jpg, 'DSC_1.jpg')).readAsString(),
        'new user content',
      );
      await file(jpg, 'DSC_1_恢复_1.jpg', 'another existing file');
      await c.restoreSources({
        p.join(jpg, 'DSC_1.jpg'): ConflictAction.keepBoth,
      });
      expect(
        c.restoration!.restored[p.join(jpg, 'DSC_1.jpg')],
        p.join(jpg, 'DSC_1_恢复_2.jpg'),
      );
      expect(
        await File(p.join(jpg, 'DSC_1_恢复_2.jpg')).readAsString(),
        'original JPG',
      );
      expect(
        await File(p.join(jpg, 'DSC_1_恢复_1.jpg')).readAsString(),
        'another existing file',
      );
      expect(
        await File(p.join(jpg, 'DSC_1.jpg')).readAsString(),
        'new user content',
      );
    },
  );

  test(
    'an existing identical original is reused without changing it',
    () async {
      final c = await started();
      await c.export();
      await c.cleanSources();
      final identical = await file(jpg, 'DSC_1.jpg', 'original JPG');
      final sentinel = DateTime(2021, 2, 3);
      await identical.setLastModified(sentinel);
      expect((await c.prepareRestore()).conflicts, isEmpty);
      await c.restoreSources({});
      expect(c.restoration!.failures, isEmpty);
      expect(await identical.lastModified(), sentinel);
      expect(c.canRestore, isFalse);
    },
  );

  test(
    'restore refuses a corrupt archive and never produces that original',
    () async {
      final c = await started();
      await c.export();
      await c.cleanSources();
      await File(
        p.join(c.result!.directory, 'RAW/Day1/DSC_1.NEF'),
      ).writeAsString('corrupt RAW!');
      await c.restoreSources({});
      expect(c.restoration!.failures, contains(p.join(raw, 'Day1', 'DSC_1.NEF')));
      expect(await File(p.join(raw, 'Day1', 'DSC_1.NEF')).exists(), isFalse);
    },
  );

  test(
    'restore rejects a symbolic-link parent and writes nothing outside the original tree',
    () async {
      final c = await started();
      await c.export();
      await c.cleanSources();
      await Directory(p.join(raw, 'Day1')).delete();
      final outside = await Directory(p.join(fixture.path, 'outside')).create();
      await Link(p.join(raw, 'Day1')).create(outside.path);
      await c.restoreSources({});
      expect(c.restoration!.failures, contains(p.join(raw, 'Day1', 'DSC_1.NEF')));
      expect(await outside.list().length, 0);
    },
    skip: Platform.isWindows ? 'Symlinks need extra Windows privileges' : false,
  );

  test(
    'a committed archive is recovered from journal when the final task save never happened',
    () async {
      final c = await started();
      await c.prepareToClose();
      final base = c.snapshot;
      c.dispose();
      controllers.remove(c);
      final archive = await RawExporter().export(
        plan: base.plan!,
        outputRoot: output,
        includeJpg: true,
        token: CancellationToken(),
        onBatchReady: (checkpoint) async {
          final j = base.toJson();
          j['archive'] = encodeArchive(checkpoint);
          j['phase'] = 'copying';
          await store.save(TaskSnapshot.fromJson(j));
        },
      );
      final next = controller();
      await next.initialize();
      expect(next.error, isNull);
      expect(next.result!.directory, archive.directory);
      expect(next.result!.receipts.length, 2);
      expect(next.canExport, isFalse);
    },
  );

  test(
    'verified-before-commit records and a truncated final journal line recover safely',
    () async {
      final c = await started();
      await c.prepareToClose();
      final base = c.snapshot;
      c.dispose();
      controllers.remove(c);
      final archive = await RawExporter().export(
        plan: base.plan!,
        outputRoot: output,
        includeJpg: true,
        token: CancellationToken(),
        onBatchReady: (checkpoint) async {
          await store.save(
            TaskSnapshot.fromJson({
              ...base.toJson(),
              'archive': encodeArchive(checkpoint),
            }),
          );
        },
      );
      final log = File(p.join(archive.directory, '逐文件记录.jsonl'));
      final rows = (await log.readAsLines())
          .map(jsonDecode)
          .where((r) => r['status'] != 'copied')
          .map(jsonEncode);
      await log.writeAsString('${rows.join('\n')}\n{"status":');
      final next = controller();
      await next.initialize();
      expect(next.error, isNull);
      expect(next.result!.receipts.length, 2);
      expect(next.canExport, isFalse);
    },
  );

  test(
    'cleanup interrupted after delete intent is recovered only with a valid archive copy',
    () async {
      final c = await started();
      await c.export();
      await c.prepareToClose();
      final snapshot = c.snapshot;
      c.dispose();
      controllers.remove(c);
      final path = p.join(jpg, 'DSC_1.jpg');
      await File(path).delete();
      await File(
        p.join(snapshot.archive!.directory, '源文件清理记录.jsonl'),
      ).writeAsString(
        '${jsonEncode({'status': 'deleting', 'source': path})}\n',
      );
      final next = controller();
      await next.initialize();
      expect(next.error, isNull);
      expect(next.cleanup!.deleted, [path]);
      expect(next.canRestore, isTrue);
      expect(await File(p.join(raw, 'Day1', 'DSC_1.NEF')).exists(), isTrue);
    },
  );

  test(
    'restore interrupted after commit is recovered from verified records',
    () async {
      final c = await started();
      await c.export();
      await c.cleanSources();
      await c.prepareToClose();
      final base = c.snapshot;
      c.dispose();
      controllers.remove(c);
      await SourceRestorer().restore(task: base, token: CancellationToken());
      final log = File(p.join(base.archive!.directory, '源位置恢复记录.jsonl'));
      final rows = (await log.readAsLines())
          .map(jsonDecode)
          .where((r) => r['status'] != 'restored')
          .map(jsonEncode);
      await log.writeAsString('${rows.join('\n')}\n');
      final next = controller();
      await next.initialize();
      expect(next.error, isNull);
      expect(next.restoration!.restored.length, 2);
      expect(next.canRestore, isFalse);
    },
  );

  test(
    'task metadata falls back to a valid previous save instead of losing the task',
    () async {
      final c = await started();
      c.updateView(search: 'saved');
      await c.saveNow();
      final id = c.currentTaskId;
      await c.prepareToClose();
      c.dispose();
      controllers.remove(c);
      await File(
        p.join(store.directory.path, '$id.task.json'),
      ).writeAsString('{broken');
      final next = controller();
      await next.initialize();
      expect(next.error, isNull);
      expect(next.currentTaskId, id);
      expect(next.plan!.items.length, 1);
    },
  );

  test(
    'history retains multiple tasks and reopening does not archive automatically',
    () async {
      final c = await started();
      final first = c.currentTaskId;
      await c.newTask();
      c.setSource(jpg: jpg, raw: raw);
      c.setOutput(output);
      await c.scan();
      final second = c.currentTaskId;
      final history = await c.history();
      expect(history.map((t) => t.id).toSet(), {first, second});
      await c.openTask(first);
      expect(c.currentTaskId, first);
      expect(c.result, isNull);
      expect(await Directory(output).list().length, 0);
    },
  );

  test(
    'a task cannot be opened concurrently even by two controllers in the same process',
    () async {
      final c = await started();
      await c.saveNow();
      final other = controller();
      await other.openTask(c.currentTaskId);
      expect(other.error, contains('另一个窗口'));
    },
  );

  test(
    'serialized task paths cannot escape their source or archive directories',
    () async {
      final c = await started();
      await c.export();
      final encoded = jsonDecode(jsonEncode(c.snapshot.toJson()));
      encoded['archive']['receipts'][0]['destination'] = '../outside.NEF';
      expect(() => TaskSnapshot.fromJson(encoded), throwsFormatException);
    },
  );

  test(
    'recovery removes recorded staging files while preserving unrecognized partial files',
    () async {
      final c = await started();
      await c.export();
      final state = c.snapshot;
      final root = c.result!.directory;
      final destination = p.join('RAW', 'Day1', 'DSC_1.NEF');
      final relative = '$destination.shipian-test.partial';
      final staging = await file(root, relative, 'partial');
      final unrelated = await file(
        root,
        'RAW/Day1/DSC_1.NEF.partial',
        'keep this file',
      );
      await File(p.join(root, '逐文件记录.jsonl')).writeAsString(
        '${jsonEncode({'status': 'copying', 'file': destination, 'temporary': relative})}\n',
        mode: FileMode.append,
      );
      await TaskRecovery().recover(state);
      expect(await staging.exists(), isFalse);
      expect(await unrelated.readAsString(), 'keep this file');
    },
  );
  test(
    'a cleanup after restoration is newer than the old restore journal on restart',
    () async {
      var c = await started();
      await c.export();
      await c.cleanSources();
      await c.restoreSources({});
      expect(c.canRestore, isFalse);
      await c.cleanSources();
      expect(c.error, isNull);
      c = await restart(c);
      expect(c.canRestore, isTrue);
      expect(c.removedSources.length, 2);
      expect(await File(p.join(jpg, 'DSC_1.jpg')).exists(), isFalse);
    },
  );

  test(
    'existing archive folders can be imported without copying the photos again',
    () async {
      final c = await started();
      await c.export();
      await c.cleanSources();
      final imported = await importArchive(c.result!.directory);
      final recovered = await TaskRecovery().recover(imported);
      expect(recovered.archive!.directory, c.result!.directory);
      expect(recovered.cleanup!.deleted.length, 2);
      expect(SourceRestorer().targets(recovered).length, 2);
      expect(await Directory(output).list().length, 1);
    },
  );

  test(
    'restore staging recorded before a crash is removed while unrelated files remain',
    () async {
      final c = await started();
      await c.export();
      await c.cleanSources();
      final original = p.join(jpg, 'DSC_1.jpg');
      final temporary = await file(
        jpg,
        'DSC_1.jpg.shipian-stage.partial',
        'partial bytes',
      );
      final unrelated = await file(jpg, 'DSC_1.jpg.partial', 'user content');
      await File(p.join(c.result!.directory, '源位置恢复记录.jsonl')).writeAsString(
        '${jsonEncode({'status': 'copying', 'source': original, 'destination': original, 'temporary': temporary.path})}\n',
      );
      await TaskRecovery().recover(c.snapshot);
      expect(await temporary.exists(), isFalse);
      expect(await unrelated.readAsString(), 'user content');
    },
  );
  test(
    'a restored file removed later is available for restoration again after restart',
    () async {
      var c = await started();
      await c.export();
      await c.cleanSources();
      await c.restoreSources({});
      await File(p.join(jpg, 'DSC_1.jpg')).delete();
      c = await restart(c);
      expect(c.canRestore, isTrue);
      expect((await c.prepareRestore()).targets.map((r) => r.source.path), [
        p.join(jpg, 'DSC_1.jpg'),
      ]);
    },
  );
  test(
    'a newer interrupted deletion takes precedence over an older completed restoration',
    () async {
      final c = await started();
      await c.export();
      await c.cleanSources();
      await c.restoreSources({});
      final original = p.join(jpg, 'DSC_1.jpg');
      await File(p.join(c.result!.directory, '源文件清理记录.jsonl')).writeAsString(
        '${jsonEncode({'status': 'deleting', 'source': original, 'time': DateTime.now().add(const Duration(seconds: 1)).toIso8601String()})}\n',
        mode: FileMode.append,
      );
      await File(original).delete();
      final recovered = await TaskRecovery().recover(c.snapshot);
      expect(recovered.removedSources, {original});
      expect(SourceRestorer().targets(recovered).map((r) => r.source.path), [
        original,
      ]);
    },
  );
}
