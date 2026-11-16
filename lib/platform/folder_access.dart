import 'dart:io';
import 'package:flutter/services.dart';

class FolderAccess {
  static const _channel = MethodChannel('shipian/folders');
  Future<String?> remember(String path) async {
    if (!Platform.isMacOS) return null;
    return _channel.invokeMethod<String>('remember', {'path': path});
  }

  Future<void> restore(String path, String bookmark) async {
    if (!Platform.isMacOS) return;
    final resolved = await _channel.invokeMethod<String>('restore', {
      'bookmark': bookmark,
    });
    if (resolved != path) throw const FileSystemException('目录位置已变化，请重新选择原目录授权');
  }
}
