import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'atomic_commit.dart';
import 'converter.dart';
import 'matcher.dart';
import 'models.dart';

const rasterPreviewExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.bmp',
  '.gif',
};
final previewExtensions = {...rasterPreviewExtensions, ...rawExtensions};

class PreviewEntry {
  const PreviewEntry(this.path, {this.label});
  final String path;
  final String? label;
  String get name => p.basename(path);
  String get title => label ?? name;
  bool get isRaw => rawExtensions.contains(p.extension(path).toLowerCase());
}

List<PreviewEntry> matchedPreviews(
  MatchPlan plan,
  Map<String, String> archives,
) {
  final entries = <String, PreviewEntry>{};
  for (final item in plan.items) {
    for (final file in [item.jpg, ...item.candidates]) {
      final path = archives[file.path] ?? file.path;
      entries[path] = PreviewEntry(path, label: file.relativePath);
    }
  }
  return entries.values.toList(growable: false);
}

Future<List<PreviewEntry>> scanPreviewFolder(
  String root,
  CancellationToken token,
) async {
  final real = await canonicalDirectory(root);
  final pending = [Directory(real)], entries = <PreviewEntry>[];
  while (pending.isNotEmpty) {
    token.check();
    await for (final entity in pending.removeLast().list(followLinks: false)) {
      token.check();
      if (p.basename(entity.path).startsWith('.')) continue;
      if (entity is Directory) {
        pending.add(entity);
      } else if (entity is File &&
          previewExtensions.contains(p.extension(entity.path).toLowerCase())) {
        entries.add(
          PreviewEntry(entity.path, label: p.relative(entity.path, from: real)),
        );
      }
    }
  }
  entries.sort((a, b) => a.title.compareTo(b.title));
  return entries;
}

class _PreviewJob {
  _PreviewJob(this.entry, this.token, this.thumbnail);
  final PreviewEntry entry;
  final CancellationToken token;
  final bool thumbnail;
  final done = Completer<File>();
}

class PhotoPreviewService {
  PhotoPreviewService({
    this.cacheDirectory,
    RawDecoder? decoder,
    this.maxCacheBytes = 128 * 1024 * 1024,
  }) : decoder = decoder ?? NativeRawDecoder(preview: true);
  final Directory? cacheDirectory;
  final RawDecoder decoder;
  final int maxCacheBytes;
  final _jobs = Queue<_PreviewJob>();
  _PreviewJob? _active;
  bool _closed = false, _working = false;
  Future<void>? _worker;
  Future<Directory>? _cache;

  Future<File> load(
    PreviewEntry entry,
    CancellationToken token, {
    bool thumbnail = false,
  }) {
    if (_closed) return Future.error(TaskCancelled());
    if (!entry.isRaw) return _raster(entry.path, token);
    final job = _PreviewJob(entry, token, thumbnail);
    _jobs.add(job);
    if (!_working) {
      _working = true;
      _worker = Future<void>.microtask(_drain);
    }
    return job.done.future;
  }

  Future<File> _raster(String path, CancellationToken token) async {
    token.check();
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('图片不存在或无法读取');
    }
    token.check();
    return File(path);
  }

  Future<void> _drain() async {
    try {
      while (_jobs.isNotEmpty) {
        final job = _jobs.firstWhere(
          (j) => !j.thumbnail,
          orElse: () => _jobs.first,
        );
        _jobs.remove(job);
        _active = job;
        try {
          job.token.check();
          if (_closed) throw TaskCancelled();
          job.done.complete(await _raw(job.entry, job.token));
        } catch (error, trace) {
          job.done.completeError(error, trace);
        } finally {
          _active = null;
        }
      }
    } finally {
      _working = false;
    }
  }

  Future<Directory> _cacheRoot() => _cache ??= (() async {
    final root =
        cacheDirectory ??
        Directory(
          p.join((await getTemporaryDirectory()).path, 'raw-previews-v1'),
        );
    await root.create(recursive: true);
    final cache = Directory(await root.resolveSymbolicLinks());
    await for (final entity in cache.list(followLinks: false)) {
      if (entity is Directory &&
          p.basename(entity.path).startsWith('.raw-preview-') &&
          DateTime.now().difference((await entity.stat()).modified) >
              const Duration(hours: 1)) {
        final partial = File(p.join(entity.path, 'preview.jpg'));
        if (await FileSystemEntity.type(partial.path, followLinks: false) ==
            FileSystemEntityType.file) {
          await partial.delete();
        }
        if (await entity.list(followLinks: false).isEmpty) {
          await entity.delete();
        }
      }
    }
    return cache;
  })();

  Future<File> _raw(PreviewEntry entry, CancellationToken token) async {
    final source = await _raster(entry.path, token);
    final real = await source.resolveSymbolicLinks();
    final stat = await source.stat();
    final key = sha256
        .convert(
          utf8.encode(
            'raw-preview-v1|$real|${stat.size}|${stat.modified.microsecondsSinceEpoch}',
          ),
        )
        .toString();
    final cache = await _cacheRoot();
    final file = File(p.join(cache.path, '$key.jpg'));
    if (await _validJpeg(file)) {
      await file.setLastModified(DateTime.now());
      token.check();
      return file;
    }
    // Never overwrite an unexpected file or link in the cache namespace.
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FormatException('预览缓存损坏，请清理缓存后重试');
    }
    final temporary = await cache.createTemp('.raw-preview-');
    try {
      final staged = File(p.join(temporary.path, 'preview.jpg'));
      await decoder.decode(
        input: real,
        output: staged.path,
        format: ImageFormat.jpg,
        quality: 88,
        token: token,
      );
      token.check();
      final after = await source.stat();
      if (after.size != stat.size ||
          after.modified != stat.modified ||
          await source.resolveSymbolicLinks() != real) {
        throw const FormatException('图片已变化，请重新打开');
      }
      if (!await _validJpeg(staged)) throw const FormatException('无法生成 RAW 预览');
      commitWithoutReplacing(staged.path, file.path);
      await _prune(cache, keep: file.path);
      return file;
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<bool> _validJpeg(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    final handle = await file.open();
    try {
      if (await handle.length() < 16) return false;
      final head = await handle.read(2);
      await handle.setPosition((await handle.length()) - 2);
      final tail = await handle.read(2);
      return head[0] == 255 &&
          head[1] == 216 &&
          tail[0] == 255 &&
          tail[1] == 217;
    } finally {
      await handle.close();
    }
  }

  Future<void> _prune(Directory cache, {String? keep}) async {
    final files = <(File, FileStat)>[];
    await for (final entity in cache.list(followLinks: false)) {
      if (entity is File &&
          RegExp(r'^[a-f0-9]{64}\.jpg$').hasMatch(p.basename(entity.path))) {
        files.add((entity, await entity.stat()));
      }
    }
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    var total = files.fold(0, (sum, f) => sum + f.$2.size);
    for (final entry in files) {
      if (total <= maxCacheBytes) break;
      if (entry.$1.path == keep) continue;
      await entry.$1.delete();
      total -= entry.$2.size;
    }
  }

  Future<void> cancelPending() async {
    _active?.token.cancelled = true;
    for (final job in _jobs) {
      job.token.cancelled = true;
    }
    await _worker;
  }

  Future<void> clearCache() async {
    await cancelPending();
    final root = await _cacheRoot();
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File &&
          RegExp(r'^[a-f0-9]{64}\.jpg$').hasMatch(p.basename(entity.path))) {
        await entity.delete();
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    await cancelPending();
  }
}
