import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'atomic_commit.dart';
import 'integrity.dart';
import 'matcher.dart';
import 'models.dart';
import 'task_snapshot.dart';

class SourceRestorer {
  List<ArchiveReceipt> targets(TaskSnapshot task) {
    final removed = task.cleanup?.deleted.toSet() ?? {};
    return [
      for (final r in task.archive?.receipts ?? <ArchiveReceipt>[])
        if (removed.contains(r.source.path) &&
            !(task.restore?.restored.containsKey(r.source.path) ?? false))
          r,
    ];
  }

  Future<RestorePreview> preview(
    TaskSnapshot task,
    CancellationToken token,
  ) async {
    validateSnapshot(task);
    final candidates = targets(task);
    final conflicts = <RestoreConflict>[];
    for (final receipt in candidates) {
      token.check();
      final type = await FileSystemEntity.type(
        receipt.source.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) continue;
      if (type == FileSystemEntityType.file &&
          p.equals(
            await File(receipt.source.path).resolveSymbolicLinks(),
            receipt.source.path,
          ) &&
          await hashFile(File(receipt.source.path), token) == receipt.sha256) {
        continue;
      }
      conflicts.add(
        RestoreConflict(
          receipt: receipt,
          existingBytes: type == FileSystemEntityType.file
              ? (await File(receipt.source.path).stat()).size
              : -1,
        ),
      );
    }
    return RestorePreview(targets: candidates, conflicts: conflicts);
  }

  Future<RestoreResult> restore({
    required TaskSnapshot task,
    required CancellationToken token,
    Map<String, ConflictAction> conflicts = const {},
    void Function(CopyProgress)? onProgress,
  }) async {
    validateSnapshot(task);
    final selected = targets(task);
    final restored = <String, String>{}, failures = <String, String>{};
    final skipped = <String>[];
    var cancelled = false, processed = 0, bytes = 0;
    String? error;
    final root = await canonicalDirectory(task.archive!.directory);
    if (!p.equals(root, task.archive!.directory)) {
      throw const FormatException('归档目录位置已变化');
    }
    final journal = await File(
      p.join(root, '源位置恢复记录.jsonl'),
    ).open(mode: FileMode.append);
    Future<void> log(Map<String, Object?> row) async {
      await journal.writeString(
        '${jsonEncode({...row, 'time': DateTime.now().toIso8601String()})}\n',
      );
      await journal.flush();
    }

    final totalBytes = selected.fold<int>(0, (sum, r) => sum + r.source.size);
    void progress(ArchiveReceipt receipt, int current, bool verifying) =>
        onProgress?.call(
          CopyProgress(
            completed: processed,
            total: selected.length,
            bytes: bytes + current,
            totalBytes: totalBytes,
            file: receipt.source.path,
            verifying: verifying,
          ),
        );
    try {
      for (final receipt in selected) {
        File? temporary;
        var created = false, committed = false;
        var destination = receipt.source.path;
        try {
          token.check();
          progress(receipt, 0, true);
          final archivePath = p.join(root, receipt.destinationRelativePath);
          final sourceStat = await File(archivePath).stat();
          final sourceSnapshot = PhotoFile(
            path: archivePath,
            relativePath: receipt.destinationRelativePath,
            size: sourceStat.size,
            modifiedMicros: sourceStat.modified.microsecondsSinceEpoch,
          );
          await checkSnapshot(sourceSnapshot, root);
          if (sourceStat.size != receipt.source.size ||
              await hashFile(File(archivePath), token) != receipt.sha256) {
            throw FileSystemException('归档副本校验失败，无法恢复', archivePath);
          }
          final originalRoot = receipt.kind == PhotoKind.raw
              ? task.plan!.rawRoot
              : task.plan!.jpgRoot;
          await _safeParent(destination, originalRoot);
          final type = await FileSystemEntity.type(
            destination,
            followLinks: false,
          );
          if (type != FileSystemEntityType.notFound) {
            if (type == FileSystemEntityType.file &&
                p.equals(
                  await File(destination).resolveSymbolicLinks(),
                  destination,
                ) &&
                await hashFile(File(destination), token) == receipt.sha256) {
              restored[receipt.source.path] = destination;
              await log({
                'status': 'restored',
                'source': receipt.source.path,
                'destination': destination,
                'reused': true,
              });
              processed++;
              bytes += receipt.source.size;
              progress(receipt, 0, false);
              continue;
            }
            if (conflicts[receipt.source.path] != ConflictAction.keepBoth) {
              skipped.add(receipt.source.path);
              processed++;
              bytes += receipt.source.size;
              progress(receipt, 0, false);
              continue;
            }
            destination = await _alternative(receipt.source.path);
          }
          temporary = File('$destination.shipian-${taskId()}.partial');
          await temporary.create(exclusive: true);
          created = true;
          await log({
            'status': 'copying',
            'source': receipt.source.path,
            'destination': destination,
            'temporary': temporary.path,
          });
          final output = await temporary.open(mode: FileMode.writeOnly);
          var written = 0;
          try {
            await for (final chunk in File(archivePath).openRead()) {
              token.check();
              await output.writeFrom(chunk);
              written += chunk.length;
              progress(receipt, written, false);
            }
            await output.flush();
          } finally {
            await output.close();
          }
          token.check();
          progress(receipt, written, true);
          await checkSnapshot(sourceSnapshot, root);
          if (written != receipt.source.size ||
              await hashFile(temporary, token) != receipt.sha256) {
            throw FileSystemException('恢复副本校验失败', destination);
          }
          await temporary.setLastModified(
            DateTime.fromMicrosecondsSinceEpoch(receipt.source.modifiedMicros),
          );
          await _safeParent(destination, originalRoot);
          token.check();
          await log({
            'status': 'verified',
            'source': receipt.source.path,
            'destination': destination,
          });
          commitWithoutReplacing(temporary.path, destination);
          committed = true;
          restored[receipt.source.path] = destination;
          await log({
            'status': 'restored',
            'source': receipt.source.path,
            'destination': destination,
          });
        } on TaskCancelled {
          cancelled = true;
        } on FileSystemException catch (exception) {
          failures[receipt.source.path] = exception.toString();
          if (committed) rethrow;
          await log({
            'status': 'failed',
            'source': receipt.source.path,
            'error': exception.toString(),
          });
        } finally {
          if (created &&
              !committed &&
              temporary != null &&
              await temporary.exists()) {
            await temporary.delete();
          }
        }
        if (cancelled) break;
        processed++;
        bytes += receipt.source.size;
        progress(receipt, 0, false);
      }
    } on TaskCancelled {
      cancelled = true;
    } on FileSystemException catch (exception) {
      error = '恢复已停止：$exception';
    } finally {
      try {
        await journal.close();
      } on FileSystemException catch (exception) {
        error = '恢复日志关闭失败：$exception';
      }
    }
    return RestoreResult(
      restored: restored,
      skipped: skipped,
      failures: failures,
      cancelled: cancelled || token.cancelled,
      error: error,
    );
  }

  Future<void> _safeParent(String destination, String root) async {
    if (!p.equals(await canonicalDirectory(root), root) ||
        !p.isWithin(root, destination)) {
      throw FileSystemException('原目录位置已变化，无法恢复', root);
    }
    final relative = p.relative(p.dirname(destination), from: root);
    if (relative == '.') return;
    validateRelative(relative);
    var current = root;
    for (final part in p.split(relative)) {
      current = p.join(current, part);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(current).create();
      } else if (type != FileSystemEntityType.directory) {
        throw FileSystemException('原目录被文件或符号链接占用', current);
      }
      if (!p.equals(await Directory(current).resolveSymbolicLinks(), current)) {
        throw FileSystemException('原目录被替换，无法恢复', current);
      }
    }
  }

  Future<String> _alternative(String original) async {
    for (var i = 1; i < 10000; i++) {
      final path = p.join(
        p.dirname(original),
        '${p.basenameWithoutExtension(original)}_恢复_$i${p.extension(original)}',
      );
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return path;
      }
    }
    throw FileSystemException('无法生成不重名的恢复文件名', original);
  }
}
