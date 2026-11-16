import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unicode;
import 'models.dart';

const rawExtensions = {
  '.3fr',
  '.ari',
  '.arw',
  '.bay',
  '.cap',
  '.cr2',
  '.cr3',
  '.crw',
  '.dcr',
  '.dcs',
  '.dng',
  '.drf',
  '.eip',
  '.erf',
  '.fff',
  '.gpr',
  '.iiq',
  '.k25',
  '.kdc',
  '.mdc',
  '.mef',
  '.mos',
  '.mrw',
  '.nef',
  '.nrw',
  '.obm',
  '.orf',
  '.ori',
  '.pef',
  '.ptx',
  '.pxn',
  '.r3d',
  '.raf',
  '.raw',
  '.rwl',
  '.rw2',
  '.rwz',
  '.sr2',
  '.srf',
  '.srw',
  '.x3f',
};

String nameKey(String path) => unicode
    .nfc(p.basenameWithoutExtension(path))
    .toLowerCase()
    .replaceAll('ß', 'ss')
    .replaceAll('ς', 'σ');

bool isInsideOrEqual(String path, String root) =>
    p.equals(path, root) || p.isWithin(root, path);

Future<String> canonicalDirectory(String path) async {
  if (!await Directory(path).exists()) {
    throw FileSystemException('文件夹不存在或无法访问', path);
  }
  return Directory(path).resolveSymbolicLinks();
}

class PhotoMatcher {
  Future<List<PhotoFile>> scanRaw(String root, CancellationToken token) async =>
      _scan(await canonicalDirectory(root), rawExtensions, token, (_) {});

  Future<MatchPlan> scan({
    required String jpgRoot,
    required String rawRoot,
    required CancellationToken token,
    bool allowEmpty = false,
    void Function(String, int)? onProgress,
  }) async {
    final jpgPath = await canonicalDirectory(jpgRoot);
    final rawPath = await canonicalDirectory(rawRoot);
    final jpgs = await _scan(
      jpgPath,
      {'.jpg', '.jpeg'},
      token,
      (n) => onProgress?.call('扫描 JPG', n),
    );
    if (jpgs.isEmpty && !allowEmpty) {
      throw const FormatException('这个文件夹中没有 JPG / JPEG 图片，请检查已选 JPG 来源。');
    }
    final raws = await _scan(
      rawPath,
      rawExtensions,
      token,
      (n) => onProgress?.call('扫描 RAW', n),
    );
    final index = <String, List<PhotoFile>>{};
    for (var i = 0; i < raws.length; i++) {
      token.check();
      final file = raws[i];
      index.putIfAbsent(nameKey(file.path), () => []).add(file);
      if (i % 500 == 0) await Future<void>.delayed(Duration.zero);
    }
    final items = <MatchItem>[];
    for (var i = 0; i < jpgs.length; i++) {
      token.check();
      items.add(
        MatchItem(
          jpg: jpgs[i],
          candidates: List.unmodifiable(
            index[nameKey(jpgs[i].path)] ?? <PhotoFile>[],
          ),
        ),
      );
      if (i % 500 == 0) await Future<void>.delayed(Duration.zero);
    }
    return MatchPlan(
      jpgRoot: jpgPath,
      rawRoot: rawPath,
      items: List.unmodifiable(items),
      rawCount: raws.length,
    );
  }

  Future<List<PhotoFile>> _scan(
    String root,
    Set<String> extensions,
    CancellationToken token,
    void Function(int) progress,
  ) async {
    final files = <PhotoFile>[];
    final pending = [Directory(root)];
    while (pending.isNotEmpty) {
      token.check();
      final directory = pending.removeLast();
      // Non-recursive traversal lets us prune hidden directories. Errors propagate:
      // an unreadable directory might contain another RAW with the same name.
      await for (final entity in directory.list(followLinks: false)) {
        token.check();
        if (p.basename(entity.path).startsWith('.')) continue;
        if (entity is Directory) {
          pending.add(entity);
        } else if (entity is File &&
            extensions.contains(p.extension(entity.path).toLowerCase())) {
          final stat = await entity.stat();
          if (stat.type != FileSystemEntityType.file) {
            throw FileSystemException('扫描期间文件发生变化，请重新扫描', entity.path);
          }
          files.add(
            PhotoFile(
              path: entity.path,
              relativePath: p.relative(entity.path, from: root),
              size: stat.size,
              modifiedMicros: stat.modified.microsecondsSinceEpoch,
            ),
          );
          if (files.length % 100 == 0) progress(files.length);
        }
      }
    }
    files.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    progress(files.length);
    return files;
  }
}
