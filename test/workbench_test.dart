import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:raw_jpg_picker/app_controller.dart';
import 'package:raw_jpg_picker/core/models.dart';
import 'package:raw_jpg_picker/main.dart';
import 'package:raw_jpg_picker/ui/palette.dart';
import 'package:raw_jpg_picker/ui/photo_stage.dart';
import 'package:raw_jpg_picker/ui/workbench.dart';
import 'package:raw_jpg_picker/ui/task_dialogs.dart';
import 'package:raw_jpg_picker/ui/conversion_dialog.dart';

void main() {
  testWidgets(
    'conversion dialog switches scope and format at minimum window size',
    (tester) async {
      tester.view.physicalSize = const Size(980, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      ConversionSettings? settings;
      await tester.pumpWidget(
        MaterialApp(
          theme: Palette.theme,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  settings = await showConversionDialog(
                    context,
                    selectedCount: 3,
                    inputRoot: '/raw',
                    outputRoot: '/out',
                  );
                },
                child: const Text('转换'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('转换'));
      await tester.pumpAndSettle();
      expect(find.text('精选 3 张'), findsOneWidget);
      expect(find.text('RAW 文件夹'), findsNothing);
      expect(find.text('画质'), findsOneWidget);
      await tester.tap(find.text('整个文件夹'));
      await tester.tap(find.text('PNG'));
      await tester.pumpAndSettle();
      expect(find.text('RAW 文件夹'), findsOneWidget);
      expect(find.text('画质'), findsNothing);
      await tester.tap(find.text('开始转换'));
      await tester.pumpAndSettle();
      expect(settings!.selectedOnly, isFalse);
      expect(settings!.request.format.name, 'png');
      expect(settings!.request.inputRoot, '/raw');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'restore confirmation requires a conflict choice and keeps the archive',
    (tester) async {
      tester.view.physicalSize = const Size(980, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const source = PhotoFile(
        path: '/source/DSC.jpg',
        relativePath: 'DSC.jpg',
        size: 100,
        modifiedMicros: 1,
      );
      const receipt = ArchiveReceipt(
        source: source,
        kind: PhotoKind.jpg,
        destinationRelativePath: 'JPG/DSC.jpg',
        sha256: 'digest',
      );
      Map<String, ConflictAction>? decisions;
      await tester.pumpWidget(
        MaterialApp(
          theme: Palette.theme,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  decisions = await showRestoreConfirmation(
                    context,
                    const RestorePreview(
                      targets: [receipt],
                      conflicts: [
                        RestoreConflict(receipt: receipt, existingBytes: 200),
                      ],
                    ),
                  );
                },
                child: const Text('打开恢复'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开恢复'));
      await tester.pumpAndSettle();
      expect(find.text('归档保留；同名文件不覆盖。'), findsOneWidget);
      expect(find.text('跳过'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<ConflictAction>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('另存副本').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '恢复'));
      await tester.pumpAndSettle();
      expect(decisions, {'/source/DSC.jpg': ConflictAction.keepBoth});
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cleanup requires explicit acknowledgement and preserves files when dismissed',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(980, 760);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory temporary;
      late PickerController controller;
      await tester.runAsync(() async {
        temporary = await Directory.systemTemp.createTemp('cleanup_ui_test_');
        final jpg = await Directory('${temporary.path}/JPG').create();
        final raw = await Directory('${temporary.path}/RAW').create();
        final out = await Directory('${temporary.path}/OUT').create();
        await File('${jpg.path}/DSC.jpg').writeAsString('sample JPG');
        await File('${raw.path}/DSC.NEF').writeAsString('sample RAW');
        controller = PickerController()
          ..setSource(jpg: jpg.path, raw: raw.path)
          ..setOutput(out.path);
        await controller.scan();
        await controller.export();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: Palette.theme,
          home: Workbench(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('继续归档'), findsNothing);
      await tester.tap(find.text('清理源文件').last);
      await tester.pumpAndSettle();
      final confirm = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '删除 2 个源文件'),
      );
      expect(confirm.onPressed, isNull);
      expect(find.textContaining('永久删除'), findsOneWidget);
      await tester.tap(find.text('保留源文件'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        expect(await File('${temporary.path}/JPG/DSC.jpg').exists(), isTrue);
        expect(await File('${temporary.path}/RAW/DSC.NEF').exists(), isTrue);
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(() => temporary.delete(recursive: true));
    },
  );
  for (final size in [const Size(1400, 900), const Size(980, 760)]) {
    testWidgets('empty workbench renders without overflow at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const RawPickerApp());
      await tester.pumpAndSettle();
      expect(find.text('拾片'), findsOneWidget);
      expect(find.text('选择源文件夹'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.text('归档'), findsNothing);
      await tester.tap(find.text('匹配归档'));
      await tester.pumpAndSettle();
      expect(find.text('已选 JPG'), findsOneWidget);
      await tester.tap(find.text('选片整理'));
      await tester.pumpAndSettle();
      expect(find.text('选择源文件夹'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'filter and manual conflict selection update the real export plan',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const photo = PhotoFile(
        path: '/nonexistent/DSC.jpg',
        relativePath: 'DSC.jpg',
        size: 10,
        modifiedMicros: 1,
      );
      const rawA = PhotoFile(
        path: '/raw/A/DSC.NEF',
        relativePath: 'A/DSC.NEF',
        size: 20,
        modifiedMicros: 1,
      );
      const rawB = PhotoFile(
        path: '/raw/B/DSC.NEF',
        relativePath: 'B/DSC.NEF',
        size: 30,
        modifiedMicros: 1,
      );
      final controller = PickerController()
        ..plan = MatchPlan(
          jpgRoot: '/jpg',
          rawRoot: '/raw',
          rawCount: 2,
          items: [
            MatchItem(jpg: photo, candidates: [rawA, rawB]),
          ],
        )
        ..phase = TaskPhase.review;
      await tester.pumpWidget(
        MaterialApp(
          theme: Palette.theme,
          home: Workbench(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('DSC.jpg').first);
      await tester.pumpAndSettle();
      expect(find.text('选择 RAW'), findsOneWidget);
      tester.view.physicalSize = const Size(980, 730);
      await tester.pumpAndSettle();
      final stage = find.byType(PhotoStage);
      expect(tester.getRect(stage).width, greaterThan(490));
      await tester.tap(find.byTooltip('预览 RAW').last);
      await tester.pump();
      expect(tester.widget<PhotoStage>(stage).entry.path, rawB.path);
      expect(controller.plan!.selected, isEmpty);
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(find.text('A/DSC.NEF'));
      await tester.pump();
      expect(tester.widget<PhotoStage>(stage).entry.path, rawA.path);
      await tester.tap(find.text('JPG'));
      await tester.pumpAndSettle();
      expect(tester.widget<PhotoStage>(stage).entry.path, photo.path);
      expect(controller.plan!.selected.single.path, rawA.path);
      expect(find.text('1 RAW + 1 JPG'), findsOneWidget);
      await tester.tap(find.text('待确认').first);
      await tester.pumpAndSettle();
      expect(find.text('无结果'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
