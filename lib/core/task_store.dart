import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'task_snapshot.dart';

class TaskSummary {
  const TaskSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.phase,
    this.archivePath,
    this.unreadable = false,
  });
  final String id, title, phase;
  final DateTime updatedAt;
  final String? archivePath;
  final bool unreadable;
}

class TaskLease {
  TaskLease(this.file, this.onClosed);
  final RandomAccessFile file;
  final void Function() onClosed;
  bool _closed = false;
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await file.unlock();
    } finally {
      try {
        await file.close();
      } finally {
        onClosed();
      }
    }
  }
}

class TaskStore {
  TaskStore(this.directory);
  final Directory directory;
  static final Set<String> _localLeases = {};
  static Future<TaskStore> open() async => TaskStore(
    Directory(
      p.join((await getApplicationSupportDirectory()).path, 'tasks-v1'),
    ),
  );

  File _task(String id) {
    if (!RegExp(r'^[a-z0-9_-]{1,100}$').hasMatch(id)) {
      throw const FormatException('无效任务标识');
    }
    return File(p.join(directory.path, '$id.task.json'));
  }

  Future<TaskLease> acquire(String id) async {
    final task = _task(id);
    await directory.create(recursive: true);
    final key = p.join(
      await directory.resolveSymbolicLinks(),
      p.basename(task.path),
    );
    if (!_localLeases.add(key)) throw const FileSystemException('任务正在另一个窗口中使用');
    RandomAccessFile? file;
    try {
      file = await File('${task.path}.lock').open(mode: FileMode.append);
      await file.lock(FileLock.exclusive);
    } on FileSystemException {
      await file?.close();
      _localLeases.remove(key);
      throw const FileSystemException('任务无法锁定，可能正在另一个窗口中使用');
    }
    return TaskLease(file, () => _localLeases.remove(key));
  }

  Future<void> save(TaskSnapshot snapshot) async {
    validateSnapshot(snapshot);
    await directory.create(recursive: true);
    await _atomicWrite(_task(snapshot.id), snapshot.toJson());
    await setCurrent(snapshot.id);
  }

  Future<void> setCurrent(String? id) async {
    if (id != null) _task(id);
    await directory.create(recursive: true);
    await _atomicWrite(File(p.join(directory.path, 'current.json')), {
      'id': id,
    });
  }

  Future<String?> currentId() async {
    final file = File(p.join(directory.path, 'current.json'));
    if (!await file.exists() && !await File('${file.path}.bak').exists()) {
      return null;
    }
    final id = jsonMap(await _read(file))['id'] as String?;
    if (id != null) _task(id);
    return id;
  }

  Future<TaskSnapshot> load(String id) async =>
      TaskSnapshot.fromJson(await _read(_task(id)));

  Future<List<TaskSummary>> list() async {
    if (!await directory.exists()) return [];
    final result = <TaskSummary>[];
    await for (final file in directory.list(followLinks: false)) {
      if (file is! File || !file.path.endsWith('.task.json')) continue;
      final id = p.basename(file.path).replaceFirst('.task.json', '');
      try {
        final j = jsonMap(await _read(file));
        result.add(
          TaskSummary(
            id: id,
            title: j['jpgRoot'] == null
                ? '未命名任务'
                : p.basename(j['jpgRoot'] as String),
            updatedAt: DateTime.parse(j['updatedAt'] as String),
            phase: j['phase'] as String? ?? 'idle',
            archivePath: j['archive'] == null
                ? null
                : jsonMap(j['archive'])['directory'] as String?,
          ),
        );
      } catch (_) {
        result.add(
          TaskSummary(
            id: id,
            title: '任务无法读取',
            updatedAt: (await file.stat()).modified,
            phase: 'error',
            unreadable: true,
          ),
        );
      }
    }
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  Future<Object?> _read(File file) async {
    try {
      return jsonDecode(await file.readAsString());
    } on Object {
      final backup = File('${file.path}.bak');
      if (!await backup.exists()) rethrow;
      return jsonDecode(await backup.readAsString());
    }
  }

  Future<void> _atomicWrite(File file, Object data) async {
    final bytes = utf8.encode(jsonEncode(data));
    if (await file.exists()) {
      // Only replace the backup with a valid previous document.
      try {
        final previous = await file.readAsBytes();
        jsonDecode(utf8.decode(previous));
        await _replace(File('${file.path}.bak'), previous);
      } on FormatException {
        /* preserve the last valid backup */
      }
    }
    await _replace(file, bytes);
  }

  Future<void> _replace(File file, List<int> bytes) async {
    final temporary = File('${file.path}.${taskId()}.tmp');
    await temporary.create(exclusive: true);
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      // Replacement is intentional for app-owned metadata only, never photos.
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
