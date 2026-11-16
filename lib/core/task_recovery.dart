import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'integrity.dart';
import 'models.dart';
import 'task_snapshot.dart';

Stream<Map<String, dynamic>> journalRows(File file) async* {
  if (!await file.exists()) return;
  var remaining = '';
  await for (final chunk in file.openRead().transform(
    const Utf8Decoder(allowMalformed: true),
  )) {
    remaining += chunk;
    var newline = remaining.indexOf('\n');
    while (newline >= 0) {
      final line = remaining.substring(0, newline).trim();
      remaining = remaining.substring(newline + 1);
      if (line.isNotEmpty) yield jsonMap(jsonDecode(line));
      newline = remaining.indexOf('\n');
    }
  }
  // An interrupted append may leave only the last JSON record incomplete.
  if (remaining.trim().isNotEmpty) {
    Map<String, dynamic>? finalRow;
    try {
      finalRow = jsonMap(jsonDecode(remaining));
    } on FormatException {
      return;
    }
    yield finalRow;
  }
}

class TaskRecovery {
  Future<TaskSnapshot> recover(
    TaskSnapshot task, {
    CancellationToken? cancellation,
  }) async {
    final archive = task.archive;
    final plan = task.plan;
    if (archive == null || plan == null) return task;
    final root = archive.directory;
    if (!await Directory(root).exists()) {
      throw FileSystemException('归档目录离线或不可访问', root);
    }
    if (!p.equals(await Directory(root).resolveSymbolicLinks(), root)) {
      throw const FormatException('归档目录被替换或移动，请核对位置');
    }
    final receipts = {for (final r in archive.receipts) r.source.path: r};
    final ownTemporaries = <String>{};
    final token = cancellation ?? CancellationToken();
    final known = {
      for (final file in [
        ...plan.selected,
        ...plan.items.where((i) => i.raw != null).map((i) => i.jpg),
      ])
        file.path: file,
    };
    final verifiedPending = <String, ArchiveReceipt>{};
    void validate(ArchiveReceipt receipt) {
      validatePhoto(
        receipt.source,
        receipt.kind == PhotoKind.raw ? plan.rawRoot : plan.jpgRoot,
      );
      final expected = known[receipt.source.path];
      if (expected == null ||
          expected.size != receipt.source.size ||
          expected.modifiedMicros != receipt.source.modifiedMicros ||
          receipt.destinationRelativePath !=
              p.join(
                receipt.kind == PhotoKind.raw ? 'RAW' : 'JPG',
                receipt.source.relativePath,
              ) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(receipt.sha256)) {
        throw const FormatException('归档日志与任务不一致');
      }
    }

    await for (final row in journalRows(File(p.join(root, '逐文件记录.jsonl')))) {
      token.check();
      if (row['status'] == 'copying' && row['temporary'] is String) {
        final relative = row['temporary'] as String;
        validateRelative(relative);
        final destination = row['file'];
        if (destination is! String ||
            !relative.startsWith('$destination.shipian-') ||
            !relative.endsWith('.partial')) {
          throw const FormatException('临时文件记录无效');
        }
        ownTemporaries.add(p.join(root, relative));
      }
      if (!{'copied', 'verified', 'reusedVerified'}.contains(row['status']) ||
          row['receipt'] == null) {
        continue;
      }
      final receipt = decodeReceipt(row['receipt']);
      validate(receipt);
      if (row['file'] != receipt.destinationRelativePath) {
        throw const FormatException('归档日志路径不一致');
      }
      if (row['status'] == 'verified') {
        verifiedPending[receipt.source.path] = receipt;
      } else {
        receipts[receipt.source.path] = receipt;
        verifiedPending.remove(receipt.source.path);
      }
    }
    for (final receipt in verifiedPending.values) {
      if (await _validCopy(root, receipt, token)) {
        receipts[receipt.source.path] = receipt;
      }
    }
    // Remove only files explicitly recorded as this app's staging files.
    for (final temporary in ownTemporaries) {
      token.check();
      final type = await FileSystemEntity.type(temporary, followLinks: false);
      if (type == FileSystemEntityType.file &&
          p.equals(await File(temporary).resolveSymbolicLinks(), temporary)) {
        await File(temporary).delete();
      }
    }
    final deleted = {...?task.cleanup?.deleted};
    final deleteIntents = <String>{};
    final deletionIntentTimes = <String, DateTime>{};
    final lastDeletedAt = <String, DateTime>{};
    await for (final row in journalRows(File(p.join(root, '源文件清理记录.jsonl')))) {
      final path = row['source'];
      if (row['status'] == 'deleting' || row['status'] == 'deleted') {
        if (path is! String || !receipts.containsKey(path)) {
          throw const FormatException('清理日志超出任务范围');
        }
        if (row['status'] == 'deleted') {
          deleted.add(path);
          final time =
              DateTime.tryParse(row['time'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
          if (lastDeletedAt[path] == null ||
              time.isAfter(lastDeletedAt[path]!)) {
            lastDeletedAt[path] = time;
          }
        } else {
          deleteIntents.add(path);
          deletionIntentTimes[path] =
              DateTime.tryParse(row['time'] as String? ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
        }
      }
    }
    for (final path in deleteIntents) {
      final intendedAt = deletionIntentTimes[path]!;
      if (lastDeletedAt[path] != null &&
          !intendedAt.isAfter(lastDeletedAt[path]!)) {
        continue;
      }
      final sourceRoot = receipts[path]!.kind == PhotoKind.raw
          ? plan.rawRoot
          : plan.jpgRoot;
      // A disconnected or unauthorized source is never evidence of deletion.
      if (!await Directory(sourceRoot).exists()) continue;
      await Directory(sourceRoot).list(followLinks: false).isEmpty;
      if (await FileSystemEntity.type(path, followLinks: false) ==
              FileSystemEntityType.notFound &&
          await _validCopy(root, receipts[path]!, token)) {
        deleted.add(path);
        final time = deletionIntentTimes[path]!;
        if (lastDeletedAt[path] == null || time.isAfter(lastDeletedAt[path]!)) {
          lastDeletedAt[path] = time;
        }
      }
    }
    final restored = {...?task.restore?.restored};
    final pendingRestores = <String, String>{};
    final restoreTemporaries = <String>{};
    await for (final row in journalRows(File(p.join(root, '源位置恢复记录.jsonl')))) {
      token.check();
      if (row['status'] == 'copying') {
        final original = row['source'],
            destination = row['destination'],
            temporary = row['temporary'];
        if (original is! String ||
            destination is! String ||
            temporary is! String ||
            !receipts.containsKey(original) ||
            !p.equals(p.dirname(original), p.dirname(destination)) ||
            !temporary.startsWith('$destination.shipian-') ||
            !temporary.endsWith('.partial') ||
            !p.equals(p.dirname(temporary), p.dirname(destination))) {
          throw const FormatException('恢复临时文件记录无效');
        }
        restoreTemporaries.add(temporary);
      }
      if (!{'verified', 'restored'}.contains(row['status'])) continue;
      final original = row['source'], destination = row['destination'];
      if (original is! String ||
          destination is! String ||
          !receipts.containsKey(original) ||
          !p.equals(p.dirname(original), p.dirname(destination))) {
        throw const FormatException('恢复日志路径无效');
      }
      final restoredAt =
          DateTime.tryParse(row['time'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      if (lastDeletedAt[original]?.isAfter(restoredAt) ?? false) {
        restored.remove(original);
        pendingRestores.remove(original);
        continue;
      }
      if (row['status'] == 'restored') {
        restored[original] = destination;
        pendingRestores.remove(original);
      } else {
        pendingRestores[original] = destination;
      }
    }
    for (final entry in pendingRestores.entries) {
      if (await _validRestored(entry.value, receipts[entry.key]!, token)) {
        restored[entry.key] = entry.value;
      }
    }
    for (final entry in restored.entries.toList()) {
      if (await FileSystemEntity.type(entry.value, followLinks: false) !=
              FileSystemEntityType.file ||
          !p.equals(
            await File(entry.value).resolveSymbolicLinks(),
            entry.value,
          )) {
        restored.remove(entry.key);
      }
    }
    for (final temporary in restoreTemporaries) {
      if (await FileSystemEntity.type(temporary, followLinks: false) ==
              FileSystemEntityType.file &&
          p.equals(await File(temporary).resolveSymbolicLinks(), temporary)) {
        await File(temporary).delete();
      }
    }
    final failures = <String, String>{};
    for (final receipt in receipts.values) {
      token.check();
      final target = File(p.join(root, receipt.destinationRelativePath));
      final type = await FileSystemEntity.type(target.path, followLinks: false);
      if (type != FileSystemEntityType.file ||
          (await target.stat()).size != receipt.source.size) {
        failures[receipt.destinationRelativePath] = '归档副本缺失或大小变化';
      }
    }
    final raw = receipts.values
        .where((r) => r.kind == PhotoKind.raw)
        .map((r) => r.source.relativePath)
        .toList();
    final jpg = receipts.values
        .where((r) => r.kind == PhotoKind.jpg)
        .map((r) => r.source.relativePath)
        .toList();
    final jpgTotal = plan.items
        .where((i) => i.raw != null)
        .map((i) => i.jpg.path)
        .toSet()
        .length;
    final complete =
        raw.length == plan.selected.length &&
        jpg.length == jpgTotal &&
        failures.isEmpty;
    final recoveredArchive = ExportResult(
      directory: root,
      copied: raw,
      copiedJpg: jpg,
      failures: failures,
      cancelled: !complete,
      total: plan.selected.length,
      jpgTotal: jpgTotal,
      receipts: receipts.values.toList(),
      includesJpg: archive.includesJpg,
    );
    final recovered = TaskSnapshot(
      id: task.id,
      updatedAt: task.updatedAt,
      jpgRoot: task.jpgRoot,
      rawRoot: task.rawRoot,
      outputRoot: task.outputRoot,
      plan: plan,
      archive: recoveredArchive,
      cleanup: deleted.isEmpty
          ? task.cleanup
          : CleanupResult(
              deleted: deleted.toList(),
              failures: task.cleanup?.failures ?? {},
              cancelled: false,
              reclaimedBytes: deleted.fold(
                0,
                (sum, path) => sum + receipts[path]!.source.size,
              ),
            ),
      restore: restored.isEmpty
          ? task.restore
          : RestoreResult(
              restored: restored,
              skipped: task.restore?.skipped ?? [],
              failures: task.restore?.failures ?? {},
              cancelled: false,
            ),
      bookmarks: task.bookmarks,
      selectedIndex: task.selectedIndex,
      filter: task.filter,
      query: task.query,
      phase: complete ? 'finished' : 'review',
    );
    validateSnapshot(recovered);
    return recovered;
  }

  Future<bool> _validCopy(
    String root,
    ArchiveReceipt receipt,
    CancellationToken token,
  ) async {
    final file = File(p.join(root, receipt.destinationRelativePath));
    try {
      final stat = await file.stat();
      await checkSnapshot(
        PhotoFile(
          path: file.path,
          relativePath: receipt.destinationRelativePath,
          size: stat.size,
          modifiedMicros: stat.modified.microsecondsSinceEpoch,
        ),
        root,
      );
      return stat.size == receipt.source.size &&
          await hashFile(file, token) == receipt.sha256;
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> _validRestored(
    String path,
    ArchiveReceipt receipt,
    CancellationToken token,
  ) async {
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file ||
          !p.equals(await File(path).resolveSymbolicLinks(), path)) {
        return false;
      }
      return await File(path).length() == receipt.source.size &&
          await hashFile(File(path), token) == receipt.sha256;
    } on FileSystemException {
      return false;
    }
  }
}
