import 'package:flutter/material.dart';
import 'ui/palette.dart';
import 'ui/workbench.dart';
import 'dart:async';
import 'app_controller.dart';
import 'core/task_store.dart';
import 'platform/folder_access.dart';
import 'platform/desktop_lifecycle.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = PickerController(
    store: await TaskStore.open(),
    folderAccess: FolderAccess(),
  );
  attachDesktopLifecycle(controller);
  runApp(RawPickerApp(controller: controller));
  unawaited(controller.initialize());
}

class RawPickerApp extends StatelessWidget {
  const RawPickerApp({super.key, this.controller});
  final PickerController? controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '拾片',
    debugShowCheckedModeBanner: false,
    theme: Palette.theme,
    home: Workbench(controller: controller),
  );
}
