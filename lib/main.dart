import 'package:flutter/material.dart';
import 'ui/palette.dart';
import 'ui/culling_home.dart';
import 'dart:async';
import 'app_controller.dart';
import 'culling_controller.dart';
import 'core/task_store.dart';
import 'platform/folder_access.dart';
import 'platform/desktop_lifecycle.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = PickerController(
    store: await TaskStore.open(),
    folderAccess: FolderAccess(),
  );
  final culling = await CullingController.open();
  attachDesktopLifecycle(controller, culling: culling);
  runApp(RawPickerApp(controller: controller, cullingController: culling));
  unawaited(culling.initialize());
}

class RawPickerApp extends StatelessWidget {
  const RawPickerApp({super.key, this.controller, this.cullingController});
  final PickerController? controller;
  final CullingController? cullingController;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '拾片',
    debugShowCheckedModeBanner: false,
    theme: Palette.theme,
    home: CullingHome(
      controller: cullingController,
      legacyController: controller,
    ),
  );
}
