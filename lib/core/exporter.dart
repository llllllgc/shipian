import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'atomic_commit.dart';
import 'integrity.dart';
import 'matcher.dart';
import 'models.dart';
import 'task_snapshot.dart';

typedef _CopyJob = ({
  PhotoFile source,
  PhotoKind kind,
  String destination,
  String? requiredRaw,
});

class RawExporter {
  Future<ExportResult> export({
    required MatchPlan plan,
    required String outputRoot,
    required CancellationToken token,
    bool verifyHash = false,
    bool includeJpg = false,
    void Function(CopyProgress)? onProgress,
    ExportResult? resume,
    Set<String> removedSources = const {},
    Future<void> Function(ExportResult)? onBatchReady,
  }) async {
    late final String output;
    try {
      output = await canonicalDirectory(outputRoot);
    } on FileSystemException {
      if (resume == null) rethrow;
      output = p.normalize(outputRoot);
    }
    if (isInsideOrEqual(output, plan.jpgRoot) ||
        isInsideOrEqual(output, plan.rawRoot)) {
      throw const FormatException('保存位置需要在 JPG 和 RAW 来源文件夹之外。');
    }
    token.check();
    final selected = plan.selected;
    final jpgItems = {
      for (final item in plan.items)
        if (item.raw != null) item.jpg.path: item,
    };
    final jobs = <_CopyJob>[
      for (final raw in selected)
        (
          source: raw,
          kind: PhotoKind.raw,
          destination: p.join('RAW', raw.relativePath),
          requiredRaw: null,
        ),
      if (includeJpg)
        for (final item in jpgItems.values)
          (
            source: item.jpg,
            kind: PhotoKind.jpg,
            destination: p.join('JPG', item.jpg.relativePath),
            requiredRaw: item.raw!.relativePath,
          ),
    ];
    final totalBytes = jobs.fold<int>(0, (sum, job) => sum + job.source.size);
    final verified = verifyHash || includeJpg;
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(RegExp(r'[-:T]'), '');
    late final Directory batch;
    if (resume == null) {
      batch = await Directory(
        output,
      ).createTemp('${includeJpg ? '精选归档' : 'RAW精选'}_${stamp}_');
    } else {
      final existing = await canonicalDirectory(resume.directory);
      if (!p.equals(existing, resume.directory) ||
          !p.isWithin(output, existing) ||
          isInsideOrEqual(existing, plan.rawRoot) ||
          isInsideOrEqual(existing, plan.jpgRoot) ||
          resume.includesJpg != includeJpg) {
        throw const FormatException('原归档目录与当前任务不一致，无法继续归档。');
      }
      batch = Directory(existing);
    }
    if (onBatchReady != null) {
      await onBatchReady(
        ExportResult(
          directory: batch.path,
          copied: resume?.copied ?? [],
          copiedJpg: resume?.copiedJpg ?? [],
          failures: const {},
          cancelled: true,
          total: selected.length,
          jpgTotal: includeJpg ? jpgItems.length : 0,
          receipts: resume?.receipts ?? [],
          includesJpg: includeJpg,
        ),
      );
    }
    final reusable = {
      for (final r in resume?.receipts ?? <ArchiveReceipt>[]) r.source.path: r,
    };
    final copied = <String>[], copiedJpg = <String>[];
    final copiedRaw = <String>{};
    final receipts = <ArchiveReceipt>[];
    final failures = <String, String>{};
    final journalFile = File(p.join(batch.path, '逐文件记录.jsonl'));
    late final RandomAccessFile journal;
    try {
      journal = await journalFile.open(mode: FileMode.append);
    } on FileSystemException catch (error) {
      throw FileSystemException(
        '无法创建处理日志：${error.message}。结果位置：${batch.path}',
        journalFile.path,
      );
    }
    var finished = 0, processedBytes = 0;
    var cancelled = false;
    String? reportError;
    Future<void> log(Map<String, Object?> data) async {
      await journal.writeString('${jsonEncode(data)}\n');
      await journal.flush();
    }

    void progress(_CopyJob job, int fileBytes, {bool verifying = false}) {
      onProgress?.call(
        CopyProgress(
          completed: finished,
          total: jobs.length,
          bytes: processedBytes + fileBytes,
          totalBytes: totalBytes,
          file: job.destination,
          verifying: verifying,
        ),
      );
    }

    try {
      await File(p.join(batch.path, '导出计划.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'jpgRoot': plan.jpgRoot,
          'rawRoot': plan.rawRoot,
          'startedAt': DateTime.now().toIso8601String(),
          'verifyHash': verified,
          'includeJpg': includeJpg,
          'selected': selected.map((f) => f.toJson()).toList(),
          'jobs': jobs
              .map(
                (j) => {
                  'source': j.source.toJson(),
                  'kind': j.kind.name,
                  'destination': j.destination,
                },
              )
              .toList(),
          'matches': plan.items
              .map(
                (i) => {
                  'jpg': i.jpg.relativePath,
                  'status': i.status.name,
                  'chosen': i.raw?.relativePath,
                  'candidates': i.candidates
                      .map((f) => f.relativePath)
                      .toList(),
                },
              )
              .toList(),
        }),
        flush: true,
      );
      for (final job in jobs) {
        File? temporary;
        var committed = false, created = false;
        var fileBytes = 0;
        final source = job.source;
        final sourceRoot = job.kind == PhotoKind.raw
            ? plan.rawRoot
            : plan.jpgRoot;
        final failureKey = job.kind == PhotoKind.raw
            ? source.relativePath
            : job.destination;
        try {
          token.check();
          if (job.requiredRaw != null && !copiedRaw.contains(job.requiredRaw)) {
            throw FileSystemException('对应 RAW 未归档成功，保留这张源 JPG', source.path);
          }
          final target = p.join(batch.path, job.destination);
          final earlier = reusable[source.path];
          if (earlier != null &&
              await FileSystemEntity.type(target, followLinks: false) !=
                  FileSystemEntityType.notFound) {
            if (earlier.destinationRelativePath != job.destination ||
                earlier.source.size != source.size ||
                earlier.source.modifiedMicros != source.modifiedMicros ||
                earlier.sha256.isEmpty) {
              throw FileSystemException('已有归档记录与当前文件不一致，保留文件等待核对', target);
            }
            progress(job, 0, verifying: true);
            final stat = await File(target).stat();
            await checkSnapshot(
              PhotoFile(
                path: target,
                relativePath: job.destination,
                size: stat.size,
                modifiedMicros: stat.modified.microsecondsSinceEpoch,
              ),
              batch.path,
            );
            if (await hashFile(File(target), token) != earlier.sha256) {
              throw FileSystemException('已有归档副本校验未通过，不会覆盖', target);
            }
            final sourceExists =
                await FileSystemEntity.type(source.path, followLinks: false) !=
                FileSystemEntityType.notFound;
            if (sourceExists || !removedSources.contains(source.path)) {
              await checkSnapshot(source, sourceRoot);
              if (await hashFile(File(source.path), token) != earlier.sha256) {
                throw FileSystemException('源文件与已有归档不一致', source.path);
              }
              await checkSnapshot(source, sourceRoot);
            }
            if (job.kind == PhotoKind.raw) {
              copied.add(source.relativePath);
              copiedRaw.add(source.relativePath);
            } else {
              copiedJpg.add(source.relativePath);
            }
            receipts.add(earlier);
            await log({
              'file': job.destination,
              'status': 'reusedVerified',
              'receipt': earlier.toJson(),
            });
            processedBytes += source.size;
            finished++;
            progress(job, 0);
            continue;
          }
          await checkSnapshot(source, sourceRoot);
          await Directory(p.dirname(target)).create(recursive: true);
          temporary = File('$target.shipian-${taskId()}.partial');
          await temporary.create(exclusive: true);
          created = true;
          await log({
            'file': job.destination,
            'status': 'copying',
            'temporary': p.relative(temporary.path, from: batch.path),
          });
          final outputFile = await temporary.open(mode: FileMode.writeOnly);
          try {
            await for (final chunk in File(source.path).openRead()) {
              token.check();
              await outputFile.writeFrom(chunk);
              fileBytes += chunk.length;
              progress(job, fileBytes);
            }
            await outputFile.flush();
          } finally {
            await outputFile.close();
          }
          token.check();
          await checkSnapshot(source, sourceRoot);
          if (fileBytes != source.size ||
              await temporary.length() != source.size) {
            throw const FileSystemException('文件大小校验失败');
          }
          var digest = '';
          if (verified) {
            progress(job, fileBytes, verifying: true);
            digest = await hashFile(File(source.path), token);
            final targetHash = await hashFile(temporary, token);
            if (digest != targetHash) {
              throw const FileSystemException('SHA-256 校验失败');
            }
            await checkSnapshot(source, sourceRoot);
          }
          token.check();
          await temporary.setLastModified(
            DateTime.fromMicrosecondsSinceEpoch(source.modifiedMicros),
          );
          final receipt = ArchiveReceipt(
            source: source,
            kind: job.kind,
            destinationRelativePath: job.destination,
            sha256: digest,
          );
          await log({
            'file': job.destination,
            'status': 'verified',
            'receipt': receipt.toJson(),
          });
          commitWithoutReplacing(temporary.path, target);
          committed = true;
          if (job.kind == PhotoKind.raw) {
            copied.add(source.relativePath);
            copiedRaw.add(source.relativePath);
          } else {
            copiedJpg.add(source.relativePath);
          }
          receipts.add(receipt);
          await log({
            'file': job.destination,
            'status': 'copied',
            'bytes': fileBytes,
            'receipt': receipt.toJson(),
          });
        } on TaskCancelled {
          cancelled = true;
          await log({'file': job.destination, 'status': 'cancelled'});
        } on FileSystemException catch (error) {
          if (committed) rethrow;
          failures[failureKey] = error.toString();
          await log({
            'file': job.destination,
            'status': 'failed',
            'error': error.toString(),
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
        processedBytes += source.size;
        finished++;
        progress(job, 0);
      }
    } on TaskCancelled {
      cancelled = true;
    } on FileSystemException catch (error) {
      reportError = '任务已停止：$error';
    } finally {
      try {
        await journal.close();
      } on FileSystemException catch (error) {
        reportError = '${reportError ?? ''}\n日志关闭失败：$error'.trim();
      }
    }
    cancelled = cancelled || token.cancelled;
    ExportResult resultWith(String? error) => ExportResult(
      directory: batch.path,
      copied: List.unmodifiable(copied),
      copiedJpg: List.unmodifiable(copiedJpg),
      jpgTotal: includeJpg ? jpgItems.length : 0,
      receipts: List.unmodifiable(receipts),
      includesJpg: includeJpg,
      failures: Map.unmodifiable(failures),
      cancelled: cancelled,
      total: selected.length,
      reportError: error,
    );
    final result = resultWith(reportError);
    try {
      await _writeReports(plan, result, verified);
    } on FileSystemException catch (error) {
      return resultWith('${reportError ?? ''}\n报告写入失败：$error'.trim());
    }
    return result;
  }

  Future<void> _writeReports(
    MatchPlan plan,
    ExportResult result,
    bool verified,
  ) async {
    final copied = result.copied.toSet(), jpgCopied = result.copiedJpg.toSet();
    final rows = <List<String>>[
      [
        'JPG 相对路径',
        '匹配状态',
        'RAW 候选路径',
        '选定 RAW',
        'RAW 归档结果',
        'JPG 归档结果',
        '失败原因',
      ],
      for (final item in plan.items)
        [
          item.jpg.relativePath,
          switch (item.status) {
            MatchStatus.matched => item.manuallyChosen ? '人工指定' : '匹配成功',
            MatchStatus.missing => '未找到 RAW',
            MatchStatus.conflict => '同名冲突，跳过',
          },
          item.candidates.map((f) => f.relativePath).join('\n'),
          item.raw?.relativePath ?? '',
          item.raw == null
              ? '跳过'
              : copied.contains(item.raw!.relativePath)
              ? '成功'
              : result.failures.containsKey(item.raw!.relativePath)
              ? '失败'
              : '未执行',
          !result.includesJpg
              ? '未启用'
              : item.raw == null
              ? '跳过'
              : jpgCopied.contains(item.jpg.relativePath)
              ? '成功'
              : '未成功',
          [
            result.failures[item.raw?.relativePath],
            result.failures[p.join('JPG', item.jpg.relativePath)],
          ].whereType<String>().join('\n'),
        ],
    ];
    String cell(String s) {
      if (s.startsWith(RegExp(r'[=+@\-\t\r]'))) s = "'$s";
      return '"${s.replaceAll('"', '""')}"';
    }

    await File(p.join(result.directory, '匹配清单.csv')).writeAsString(
      '\ufeff${rows.map((r) => r.map(cell).join(',')).join('\r\n')}\r\n',
      flush: true,
    );
    await File(p.join(result.directory, '处理记录.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'jpgRoot': plan.jpgRoot,
        'rawRoot': plan.rawRoot,
        'output': result.directory,
        'jpgCount': plan.items.length,
        'rawCount': plan.rawCount,
        'selectedCount': result.total,
        'copied': result.copied,
        'copiedJpg': result.copiedJpg,
        'includeJpg': result.includesJpg,
        'failures': result.failures,
        'cancelled': result.cancelled,
        'reportError': result.reportError,
        'verification': verified ? 'SHA-256' : 'fileSize',
        'receipts': result.receipts.map((r) => r.toJson()).toList(),
        'finishedAt': DateTime.now().toIso8601String(),
      }),
      flush: true,
    );
  }
}
