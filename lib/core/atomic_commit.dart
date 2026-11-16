import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// Dart File.rename replaces an existing destination. Use the OS no-replace
// primitives so a file appearing between the check and commit is also protected.
void commitWithoutReplacing(String temporary, String destination) {
  if (Platform.isMacOS) {
    final library = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
    final rename = library
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
          int Function(Pointer<Utf8>, Pointer<Utf8>, int)
        >('renamex_np');
    final source = temporary.toNativeUtf8();
    final target = destination.toNativeUtf8();
    try {
      if (rename(source, target, 0x00000004) != 0) {
        // RENAME_EXCL
        throw FileSystemException('无法提交文件：目标已存在或磁盘不可写', destination);
      }
    } finally {
      malloc.free(source);
      malloc.free(target);
    }
  } else if (Platform.isWindows) {
    final library = DynamicLibrary.open('kernel32.dll');
    final move = library
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)
        >('MoveFileExW');
    final source = temporary.toNativeUtf16();
    final target = destination.toNativeUtf16();
    try {
      if (move(source, target, 0) == 0) {
        throw FileSystemException('无法提交文件：目标已存在或磁盘不可写', destination);
      }
    } finally {
      malloc.free(source);
      malloc.free(target);
    }
  } else {
    throw UnsupportedError('当前发行版支持 macOS 和 Windows');
  }
}
