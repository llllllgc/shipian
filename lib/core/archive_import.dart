import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'matcher.dart';
import 'models.dart';
import 'task_snapshot.dart';

Future<TaskSnapshot> importArchive(String directory) async {
  final root = await canonicalDirectory(directory);
  final report = jsonMap(
    jsonDecode(await File(p.join(root, '处理记录.json')).readAsString()),
  );
  final jobPlan = jsonMap(
    jsonDecode(await File(p.join(root, '导出计划.json')).readAsString()),
  );
  if (report['includeJpg'] != true || report['receipts'] is! List) {
    throw const FormatException('请选择包含 RAW/JPG 完整归档记录的任务文件夹');
  }
  final jpgRoot = jobPlan['jpgRoot'] as String,
      rawRoot = jobPlan['rawRoot'] as String;
  final files = <String, PhotoFile>{};
  for (final job in jobPlan['jobs'] as List) {
    final file = decodePhoto(jsonMap(job)['source']);
    files[file.path] = file;
  }
  PhotoFile resolve(String sourceRoot, String relative) =>
      files[p.join(sourceRoot, relative)] ??
      PhotoFile(
        path: p.join(sourceRoot, relative),
        relativePath: relative,
        size: 0,
        modifiedMicros: 0,
      );
  final items = (jobPlan['matches'] as List).map((value) {
    final item = jsonMap(value);
    final candidates = (item['candidates'] as List)
        .map((r) => resolve(rawRoot, r as String))
        .toList();
    return MatchItem(
      jpg: resolve(jpgRoot, item['jpg'] as String),
      candidates: candidates,
      chosenPath: item['chosen'] == null
          ? null
          : p.join(rawRoot, item['chosen'] as String),
    );
  }).toList();
  final plan = MatchPlan(
    jpgRoot: jpgRoot,
    rawRoot: rawRoot,
    items: items,
    rawCount: report['rawCount'] as int? ?? 0,
  );
  final snapshot = TaskSnapshot(
    id: taskId(),
    updatedAt: DateTime.now(),
    jpgRoot: jpgRoot,
    rawRoot: rawRoot,
    outputRoot: p.dirname(root),
    plan: plan,
    phase: 'finished',
    archive: ExportResult(
      directory: root,
      copied: List<String>.from(report['copied']),
      copiedJpg: List<String>.from(report['copiedJpg']),
      failures: Map<String, String>.from(report['failures']),
      cancelled: report['cancelled'] as bool,
      total: plan.selected.length,
      jpgTotal: items.where((i) => i.raw != null).length,
      reportError: report['reportError'] as String?,
      includesJpg: true,
      receipts: (report['receipts'] as List).map(decodeReceipt).toList(),
    ),
  );
  validateSnapshot(snapshot);
  return snapshot;
}
