import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'integrity.dart';
import 'matcher.dart';
import 'models.dart';

class SourceCleanup {
  CleanupPreview preview(
    MatchPlan plan,
    ExportResult result, {
    Set<String> alreadyDeleted = const {},
  }) {
    if (!result.includesJpg || result.reportError != null || result.cancelled) {
      return const CleanupPreview(targets: [], blockedGroups: 0);
    }
    final receipts = {
      for (final receipt in result.receipts) receipt.source.path: receipt,
    };
    final groups = <String, List<MatchItem>>{};
    for (final item in plan.items) {
      if (item.raw != null) {
        groups.putIfAbsent(item.raw!.path, () => []).add(item);
      }
    }
    final targets = <String, ArchiveReceipt>{};
    var blocked = 0;
    for (final group in groups.values) {
      final expected = [
        group.first.raw!,
        ...{for (final i in group) i.jpg.path: i.jpg}.values,
      ];
      var eligible = true;
      for (var i = 0; i < expected.length; i++) {
        final source = expected[i], receipt = receipts[expected[i].path];
        final kind = i == 0 ? PhotoKind.raw : PhotoKind.jpg;
        if (receipt == null ||
            receipt.kind != kind ||
            receipt.source.size != source.size ||
            receipt.source.modifiedMicros != source.modifiedMicros ||
            receipt.destinationRelativePath !=
                p.join(
                  kind == PhotoKind.raw ? 'RAW' : 'JPG',
                  source.relativePath,
                ) ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(receipt.sha256)) {
          eligible = false;
        }
      }
      if (!eligible) {
        blocked++;
        continue;
      }
      // Clean JPGs first, then their RAW. Each file has a complete, verified copy.
      for (final source in [...expected.skip(1), expected.first]) {
        if (!alreadyDeleted.contains(source.path)) {
          targets[source.path] = receipts[source.path]!;
        }
      }
    }
    return CleanupPreview(
      targets: List.unmodifiable(targets.values),
      blockedGroups: blocked,
    );
  }

  Future<CleanupResult> clean({
    required MatchPlan plan,
    required ExportResult archive,
    required CancellationToken token,
    Set<String> alreadyDeleted = const {},
    void Function(CopyProgress)? onProgress,
  }) async {
    final preparation = preview(plan, archive, alreadyDeleted: alreadyDeleted);
    if (preparation.targets.isEmpty) {
      return const CleanupResult(
        deleted: [],
        failures: {},
        cancelled: false,
        reclaimedBytes: 0,
      );
    }
    final root = await canonicalDirectory(archive.directory);
    if (!p.equals(root, archive.directory) ||
        isInsideOrEqual(root, plan.rawRoot) ||
        isInsideOrEqual(root, plan.jpgRoot)) {
      throw const FormatException('归档目录位置已变化，本次不会清理源文件。');
    }
    final deleted = <String>[];
    final failures = <String, String>{};
    final destinationSnapshots = <String, PhotoFile>{};
    var bytes = 0, cancelled = false;
    String? error;
    final journal = await File(
      p.join(root, '源文件清理记录.jsonl'),
    ).open(mode: FileMode.append);
    Future<void> log(Map<String, Object?> row) async {
      await journal.writeString(
        '${jsonEncode({...row, 'time': DateTime.now().toIso8601String()})}\n',
      );
      await journal.flush();
    }

    void progress(int completed, ArchiveReceipt receipt, bool verifying) {
      onProgress?.call(
        CopyProgress(
          completed: completed,
          total: preparation.targets.length,
          bytes: bytes,
          totalBytes: preparation.totalBytes,
          file: receipt.source.path,
          verifying: verifying,
        ),
      );
    }

    try {
      token.check();
      await log({
        'status': 'confirmationAccepted',
        'targets': preparation.targets.map((r) => r.toJson()).toList(),
      });
      // Preflight every pair before removing anything. A changed or missing JPG
      // or RAW blocks the whole cleanup, so the user can resolve it first.
      for (var i = 0; i < preparation.targets.length; i++) {
        final receipt = preparation.targets[i];
        token.check();
        progress(i, receipt, true);
        try {
          final sourceRoot = receipt.kind == PhotoKind.raw
              ? plan.rawRoot
              : plan.jpgRoot;
          await checkSnapshot(receipt.source, sourceRoot);
          final targetPath = p.join(root, receipt.destinationRelativePath);
          final stat = await File(targetPath).stat();
          final target = PhotoFile(
            path: targetPath,
            relativePath: receipt.destinationRelativePath,
            size: stat.size,
            modifiedMicros: stat.modified.microsecondsSinceEpoch,
          );
          await checkSnapshot(target, root);
          if (target.size != receipt.source.size ||
              await hashFile(File(targetPath), token) != receipt.sha256 ||
              await hashFile(File(receipt.source.path), token) !=
                  receipt.sha256) {
            throw FileSystemException(
              '源文件或归档副本与归档时的 SHA-256 不一致，保留源文件',
              receipt.source.path,
            );
          }
          await checkSnapshot(receipt.source, sourceRoot);
          await checkSnapshot(target, root);
          destinationSnapshots[receipt.source.path] = target;
        } on FileSystemException catch (exception) {
          failures[receipt.source.path] = exception.toString();
        }
      }
      if (failures.isNotEmpty) {
        error = '复核未通过，本次没有清理任何源文件。';
        await log({'status': 'preflightFailed', 'failures': failures});
      } else {
        for (final receipt in preparation.targets) {
          token.check();
          progress(deleted.length, receipt, false);
          try {
            final sourceRoot = receipt.kind == PhotoKind.raw
                ? plan.rawRoot
                : plan.jpgRoot;
            await checkSnapshot(receipt.source, sourceRoot);
            await checkSnapshot(
              destinationSnapshots[receipt.source.path]!,
              root,
            );
            await log({
              'status': 'deleting',
              'source': receipt.source.path,
              'destination': receipt.destinationRelativePath,
            });
            token.check();
            await File(receipt.source.path).delete();
            deleted.add(receipt.source.path);
            bytes += receipt.source.size;
            await log({
              'status': 'deleted',
              'source': receipt.source.path,
              'bytes': receipt.source.size,
            });
          } on FileSystemException catch (exception) {
            failures[receipt.source.path] = exception.toString();
            // If audit writes fail after deleting, stop instead of proceeding
            // with deletions that cannot be recorded.
            if (deleted.contains(receipt.source.path)) rethrow;
            await log({
              'status': 'failed',
              'source': receipt.source.path,
              'error': exception.toString(),
            });
          }
          progress(deleted.length, receipt, false);
        }
      }
    } on TaskCancelled {
      cancelled = true;
    } on FileSystemException catch (exception) {
      error = '清理已停止：$exception';
    } finally {
      try {
        await journal.close();
      } on FileSystemException catch (exception) {
        error = '清理日志关闭失败：$exception';
      }
    }
    cancelled = cancelled || token.cancelled;
    final summary = {
      'deleted': deleted,
      'failures': failures,
      'cancelled': cancelled,
      'reclaimedLogicalBytes': bytes,
      'error': error,
      'previouslyDeleted': alreadyDeleted.toList(),
    };
    try {
      await File(p.join(root, '源文件清理结果.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(summary),
        flush: true,
      );
    } on FileSystemException catch (exception) {
      error = '清理结果写入失败：$exception';
    }
    return CleanupResult(
      deleted: List.unmodifiable(deleted),
      failures: Map.unmodifiable(failures),
      cancelled: cancelled,
      reclaimedBytes: bytes,
      error: error,
    );
  }
}
