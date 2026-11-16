import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'models.dart';

Future<void> checkSnapshot(PhotoFile source, String root) async {
  final type = await FileSystemEntity.type(source.path, followLinks: false);
  final real = type == FileSystemEntityType.file
      ? await File(source.path).resolveSymbolicLinks()
      : '';
  if (type != FileSystemEntityType.file ||
      !p.equals(real, source.path) ||
      !p.isWithin(root, real)) {
    throw FileSystemException('源文件消失、被替换或变为符号链接，请重新匹配', source.path);
  }
  final stat = await File(source.path).stat();
  if (stat.size != source.size ||
      stat.modified.microsecondsSinceEpoch != source.modifiedMicros) {
    throw FileSystemException('源文件在扫描后发生变化，请重新匹配', source.path);
  }
}

Future<String> hashFile(File file, CancellationToken token) async {
  final chunks = file.openRead().map((chunk) {
    token.check();
    return chunk;
  });
  return (await sha256.bind(chunks).first).toString();
}
