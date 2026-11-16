import 'package:flutter/services.dart';
import '../app_controller.dart';

void attachDesktopLifecycle(PickerController controller) {
  const MethodChannel('shipian/lifecycle').setMethodCallHandler((call) async {
    if (call.method == 'prepareToClose') return controller.prepareToClose();
    throw MissingPluginException();
  });
}
