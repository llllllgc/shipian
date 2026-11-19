import 'package:flutter/services.dart';
import '../app_controller.dart';
import '../culling_controller.dart';

void attachDesktopLifecycle(
  PickerController controller, {
  CullingController? culling,
}) {
  const MethodChannel('shipian/lifecycle').setMethodCallHandler((call) async {
    if (call.method == 'prepareToClose') {
      if (!await controller.prepareToClose()) return false;
      return await culling?.prepareToClose() ?? true;
    }
    throw MissingPluginException();
  });
}
