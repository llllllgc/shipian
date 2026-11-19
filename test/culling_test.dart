import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:raw_jpg_picker/core/atomic_commit.dart';
import 'package:raw_jpg_picker/core/culling.dart';
import 'package:raw_jpg_picker/core/integrity.dart';
import 'package:raw_jpg_picker/core/models.dart';
import 'package:raw_jpg_picker/culling_controller.dart';
import 'package:raw_jpg_picker/ui/culling_home.dart';
import 'package:raw_jpg_picker/ui/palette.dart';

void main() {
  late Directory directory;
  late String root;
  setUp(() async {
    directory = Directory(
      await (await Directory.systemTemp.createTemp(
        'shipian_culling_',
      )).resolveSymbolicLinks(),
    );
    root = directory.path;
  });
  tearDown(() => directory.delete(recursive: true));
  Future<File> file(String relative, [String text = 'photo']) async {
    final result = File(p.join(root, relative));
    await result.parent.create(recursive: true);
    return result.writeAsString(text);
  }

  Future<void> pair(String name, {bool realJpg = false}) async {
    final jpg = await file('$name.jpg');
    if (realJpg) await File('test/fixtures/preview.jpg').copy(jpg.path);
    await file('$name.NEF', 'RAW:$name');
  }

  Future<CullingSession> ready() async {
    await pair('A');
    await pair('B');
    final state = await scanCullingFolder(root, CancellationToken());
    state.decisions[state.plan.items[0].jpg.path] = PickDecision.keep;
    state.decisions[state.plan.items[1].jpg.path] = PickDecision.reject;
    return state;
  }

  Future<CullingStore> store() async {
    final value = await CullingStore.open(root);
    addTearDown(value.close);
    return value;
  }

  test(
    'one mixed folder matches by parent first and by unique name second',
    () async {
      await pair('第一天/DSC_0001');
      await pair('第二天/DSC_0001');
      await file('照片/DSC_0002.JPG');
      await file('原片/dsc_0002.nef');
      await file('.hidden/hidden.jpg');
      await file('.hidden/hidden.NEF');
      await file('RAW转图片/JPG_90/converted.jpg');
      final state = await scanCullingFolder(root, CancellationToken());
      expect(state.plan.items.length, 3);
      expect(state.plan.items.every((i) => i.raw != null), isTrue);
      expect(
        state.plan.items
            .where((i) => i.jpg.name == 'DSC_0001.jpg')
            .every((i) => p.dirname(i.raw!.path) == p.dirname(i.jpg.path)),
        isTrue,
      );
      expect(state.processed, 0);
    },
  );

  test(
    'unresolved duplicate RAW blocks sorting; explicit JPG-only leaves candidates in place',
    () async {
      await file('A.jpg');
      await file('first/A.NEF');
      await file('second/A.NEF');
      final state = await scanCullingFolder(root, CancellationToken());
      state.decisions[state.plan.items.single.jpg.path] = PickDecision.keep;
      final value = await store();
      await expectLater(
        CullingOrganizer().organize(state, value, CancellationToken()),
        throwsFormatException,
      );
      state.skippedRaw.add(state.plan.items.single.jpg.path);
      await CullingOrganizer().organize(state, value, CancellationToken());
      expect(await File(p.join(root, 'JPG/A.jpg')).exists(), isTrue);
      expect(await File(p.join(root, 'first/A.NEF')).exists(), isTrue);
      expect(await File(p.join(root, 'second/A.NEF')).exists(), isTrue);
    },
  );

  test(
    'organizing moves originals into exactly three media folders without copies or content changes',
    () async {
      final state = await ready();
      final before = <String, (String, DateTime)>{};
      for (final move in state.moves) {
        before[move.source.path] = (
          await hashFile(File(move.source.path), CancellationToken()),
          (await File(move.source.path).stat()).modified,
        );
      }
      final value = await store();
      await CullingOrganizer().organize(state, value, CancellationToken());
      expect(state.finished, isTrue);
      expect(
        await File(p.join(root, '$pickedRawFolder/A.NEF')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(root, '$rejectedRawFolder/B.NEF')).exists(),
        isTrue,
      );
      expect(await File(p.join(root, 'JPG/A.jpg')).exists(), isTrue);
      expect(await File(p.join(root, 'JPG/B.jpg')).exists(), isTrue);
      for (final move in state.moves) {
        final target = File(p.join(root, move.destination));
        expect(
          await hashFile(target, CancellationToken()),
          before[move.source.path]!.$1,
        );
        expect((await target.stat()).modified, before[move.source.path]!.$2);
        expect(await File(move.source.path).exists(), isFalse);
      }
      expect(
        (await directory.list().toList())
            .whereType<Directory>()
            .map((d) => p.basename(d.path))
            .where((d) => !d.startsWith('.'))
            .toSet(),
        {pickedRawFolder, rejectedRawFolder, 'JPG'},
      );
    },
  );

  test(
    'a RAW shared by conflicting JPG votes is kept when any JPG is kept',
    () async {
      await file('first/A.jpg');
      await file('second/A.jpg');
      await file('A.NEF');
      final state = await scanCullingFolder(root, CancellationToken());
      state.decisions[state.plan.items.first.jpg.path] = PickDecision.keep;
      state.decisions[state.plan.items.last.jpg.path] = PickDecision.reject;
      expect(
        state.moves.where((m) => m.source.path.endsWith('.NEF')).length,
        1,
      );
      await CullingOrganizer().organize(
        state,
        await store(),
        CancellationToken(),
      );
      expect(
        await File(p.join(root, '$pickedRawFolder/A.NEF')).exists(),
        isTrue,
      );
      expect(await File(p.join(root, 'JPG/first/A.jpg')).exists(), isTrue);
      expect(await File(p.join(root, 'JPG/second/A.jpg')).exists(), isTrue);
    },
  );

  test(
    'missing RAW and unpaired RAW are reported without being discarded',
    () async {
      await pair('A');
      await file('missing.jpg');
      await file('orphan.NEF');
      await file('notes.txt', 'leave alone');
      final state = await scanCullingFolder(root, CancellationToken());
      for (final item in state.plan.items) {
        state.decisions[item.jpg.path] = PickDecision.reject;
      }
      expect(state.missing, 1);
      expect(state.unmatchedRaw.single.name, 'orphan.NEF');
      await CullingOrganizer().organize(
        state,
        await store(),
        CancellationToken(),
      );
      expect(await File(p.join(root, 'orphan.NEF')).exists(), isTrue);
      expect(await File(p.join(root, 'JPG/missing.jpg')).exists(), isTrue);
      expect(
        await File(p.join(root, 'notes.txt')).readAsString(),
        'leave alone',
      );
    },
  );

  test(
    'an occupied target prevents all new moves and is never overwritten',
    () async {
      final state = await ready();
      await file('$rejectedRawFolder/B.NEF', 'existing file');
      await expectLater(
        CullingOrganizer().organize(state, await store(), CancellationToken()),
        throwsA(isA<FileSystemException>()),
      );
      expect(state.started, isFalse);
      for (final move in state.moves) {
        expect(await File(move.source.path).exists(), isTrue);
      }
      expect(
        await File(p.join(root, '$rejectedRawFolder/B.NEF')).readAsString(),
        'existing file',
      );
    },
  );

  test('source changes before sorting prevent all media moves', () async {
    final state = await ready();
    await File(p.join(root, 'B.jpg')).writeAsString('changed JPG content');
    await expectLater(
      CullingOrganizer().organize(state, await store(), CancellationToken()),
      throwsA(isA<FileSystemException>()),
    );
    expect(state.moved, isEmpty);
    expect(await File(p.join(root, 'A.NEF')).exists(), isTrue);
  });

  test('target symlink cannot move photos outside the source', () async {
    if (Platform.isWindows) return;
    final state = await ready();
    final outside = await Directory(p.join(root, 'outside')).create();
    await Link(p.join(root, pickedRawFolder)).create(outside.path);
    await expectLater(
      CullingOrganizer().organize(state, await store(), CancellationToken()),
      throwsA(isA<FileSystemException>()),
    );
    expect(await outside.list().isEmpty, isTrue);
    expect(await File(p.join(root, 'A.NEF')).exists(), isTrue);
  });

  test(
    'cancelled sorting resumes from the same records and preserves preview paths',
    () async {
      final state = await ready(),
          value = await CullingStore.open(root),
          token = CancellationToken();
      await expectLater(
        CullingOrganizer().organize(
          state,
          value,
          token,
          onProgress: (done, _, _) {
            if (done == 1) token.cancelled = true;
          },
        ),
        throwsA(isA<TaskCancelled>()),
      );
      expect(state.moved.length, 1);
      await value.close();
      final resumedStore = await store(),
          resumed = (await resumedStore.load())!;
      await CullingOrganizer().recover(
        resumed,
        resumedStore,
        CancellationToken(),
      );
      expect(resumed.moved.length, 1);
      expect(await File(resumed.pathFor(resumed.raws.first)).exists(), isTrue);
      await CullingOrganizer().organize(
        resumed,
        resumedStore,
        CancellationToken(),
      );
      expect(resumed.finished, isTrue);
      expect(resumed.moved.length, 4);
      expect(await Directory(p.join(root, 'JPG/JPG')).exists(), isFalse);
    },
  );

  test(
    'a crash between rename and moved event is recovered using the prepared checksum',
    () async {
      final state = await ready(), value = await store();
      state.started = true;
      await value.save(state);
      final move = state.moves.first;
      final receipt = CullMove(
        move.source,
        move.destination,
        sha256: await hashFile(File(move.source.path), CancellationToken()),
      );
      await value.append('prepared', receipt);
      final target = File(p.join(root, move.destination));
      await target.parent.create(recursive: true);
      commitWithoutReplacing(move.source.path, target.path);
      final recovered = (await value.load())!;
      await CullingOrganizer().recover(recovered, value, CancellationToken());
      expect(recovered.moved.keys, [move.source.path]);
      await CullingOrganizer().organize(recovered, value, CancellationToken());
      expect(recovered.finished, isTrue);
    },
  );

  test(
    'invalid journal destinations and changed moved files block recovery',
    () async {
      final state = await ready(), value = await store();
      state.started = true;
      await value.save(state);
      await value.append(
        'prepared',
        CullMove(state.moves.first.source, '../escape.NEF', sha256: 'a' * 64),
      );
      await expectLater(
        CullingOrganizer().recover(state, value, CancellationToken()),
        throwsFormatException,
      );
      expect(await File(p.join(root, 'A.NEF')).exists(), isTrue);
    },
  );

  test(
    'finished sessions reopen with moved JPG and RAW paths and no nested output folders',
    () async {
      final state = await ready(), value = await store();
      await CullingOrganizer().organize(state, value, CancellationToken());
      final reopened = (await value.load())!;
      await CullingOrganizer().recover(reopened, value, CancellationToken());
      expect(reopened.finished, isTrue);
      expect(
        await File(reopened.pathFor(reopened.plan.items.first.jpg)).exists(),
        isTrue,
      );
      expect(
        await File(reopened.pathFor(reopened.raws.first)).exists(),
        isTrue,
      );
      await CullingOrganizer().organize(reopened, value, CancellationToken());
      expect(await Directory(p.join(root, 'JPG/JPG')).exists(), isFalse);
    },
  );

  test(
    'per-folder lock prevents two instances from changing the same session',
    () async {
      await store();
      await expectLater(
        CullingStore.open(root),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'decisions auto-advance, undo, and survive closing and reopening',
    () async {
      await pair('A');
      await pair('B');
      final controller = CullingController();
      await controller.openSource(root);
      expect(controller.canSort, isFalse);
      controller.decide(PickDecision.keep);
      expect(controller.session!.index, 1);
      controller.decide(PickDecision.reject);
      expect(controller.canSort, isTrue);
      controller.undo();
      expect(controller.canSort, isFalse);
      expect(controller.session!.processed, 1);
      expect(await controller.prepareToClose(), isTrue);
      controller.dispose();
      final reopened = CullingController();
      addTearDown(reopened.dispose);
      await reopened.openSource(root);
      expect(reopened.session!.count(PickDecision.keep), 1);
      expect(reopened.session!.processed, 1);
      reopened.decide(PickDecision.reject);
      await reopened.organize();
      expect(reopened.error, isNull);
      expect(reopened.session!.finished, isTrue);
      expect(reopened.canDecide, isFalse);
      await reopened.prepareToClose();
    },
  );

  test(
    'rescan preserves unchanged decisions and makes new or changed JPGs undecided',
    () async {
      await pair('A');
      final controller = CullingController();
      addTearDown(controller.dispose);
      await controller.openSource(root);
      controller.decide(PickDecision.keep);
      await pair('B');
      await controller.rescan();
      expect(controller.session!.processed, 1);
      expect(controller.canSort, isFalse);
      await File(p.join(root, 'A.jpg')).writeAsString('changed photo');
      await controller.rescan();
      expect(controller.session!.processed, 0);
      await controller.prepareToClose();
    },
  );

  test(
    'completed state uses a valid backup when its last JSON write is damaged',
    () async {
      final state = await ready(), value = await store();
      await value.save(state);
      state.index = 1;
      await value.save(state);
      await value.stateFile.writeAsString('{bad JSON');
      expect((await value.load())!.processed, 2);
    },
  );

  test(
    'interrupted sort can recover from a backup preceding its started checkpoint',
    () async {
      final state = await ready(), value = await store();
      await value.save(state);
      final token = CancellationToken();
      await expectLater(
        CullingOrganizer().organize(
          state,
          value,
          token,
          onProgress: (done, _, _) {
            if (done == 1) token.cancelled = true;
          },
        ),
        throwsA(isA<TaskCancelled>()),
      );
      await value.stateFile.writeAsString('{interrupted');
      final recovered = (await value.load())!;
      expect(recovered.started, isFalse);
      await CullingOrganizer().recover(recovered, value, CancellationToken());
      expect(recovered.moved.length, 1);
      await CullingOrganizer().organize(recovered, value, CancellationToken());
      expect(recovered.finished, isTrue);
    },
  );

  test(
    'last source and decisions restore automatically on application initialization',
    () async {
      await pair('A');
      final preference = File(p.join(root, 'app-preferences.json'));
      final first = CullingController(preferences: preference);
      await first.openSource(root);
      first.decide(PickDecision.keep);
      expect(await first.prepareToClose(), isTrue);
      first.dispose();
      final second = CullingController(preferences: preference);
      addTearDown(second.dispose);
      await second.initialize();
      expect(second.error, isNull);
      expect(second.session!.root, root);
      expect(second.session!.count(PickDecision.keep), 1);
      await second.prepareToClose();
    },
  );

  for (final size in [const Size(980, 760), const Size(1400, 900)]) {
    testWidgets(
      'home shows pictures and enables sorting only after all decisions at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = CullingController();
        await tester.runAsync(() async {
          await pair('A', realJpg: true);
          await pair('B', realJpg: true);
          await controller.openSource(root);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: Palette.theme,
            home: CullingHome(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '筛选'))
              .onPressed,
          isNull,
        );
        await tester.runAsync(
          () => tester.tap(find.widgetWithText(FilledButton, '保留')),
        );
        await tester.pumpAndSettle();
        expect(controller.session!.index, 1);
        await tester.runAsync(
          () => tester.tap(find.widgetWithText(OutlinedButton, '不要')),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '筛选'))
              .onPressed,
          isNotNull,
        );
        await tester.runAsync(
          () => tester.tap(find.widgetWithText(TextButton, '撤销')),
        );
        await tester.pumpAndSettle();
        expect(controller.session!.processed, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(controller.prepareToClose);
        controller.dispose();
      },
    );
  }
}
