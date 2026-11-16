import 'dart:math';
import 'package:path/path.dart' as p;
import 'models.dart';

Map<String, dynamic> jsonMap(Object? value) {
  if (value is! Map) throw const FormatException('任务记录格式无效');
  return Map<String, dynamic>.from(value);
}

String taskId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${Random.secure().nextInt(0x7fffffff).toRadixString(36)}';

class TaskSnapshot {
  TaskSnapshot({
    required this.id,
    required this.updatedAt,
    this.jpgRoot,
    this.rawRoot,
    this.outputRoot,
    this.plan,
    this.archive,
    this.cleanup,
    this.restore,
    this.bookmarks = const {},
    this.selectedIndex,
    this.filter = '全部',
    this.query = '',
    this.phase = 'idle',
  });
  final String id;
  final DateTime updatedAt;
  final String? jpgRoot, rawRoot, outputRoot;
  final MatchPlan? plan;
  final ExportResult? archive;
  final CleanupResult? cleanup;
  final RestoreResult? restore;
  final Map<String, String> bookmarks;
  final int? selectedIndex;
  final String filter, query, phase;
  String get title => jpgRoot == null ? '未命名任务' : p.basename(jpgRoot!);
  Set<String> get removedSources => {...?cleanup?.deleted}
    ..removeAll(
      (restore?.restored ?? {}).entries
          .where((e) => p.equals(e.key, e.value))
          .map((e) => e.key),
    );

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'updatedAt': updatedAt.toIso8601String(),
    'jpgRoot': jpgRoot,
    'rawRoot': rawRoot,
    'outputRoot': outputRoot,
    'phase': phase,
    'bookmarks': bookmarks,
    'selectedIndex': selectedIndex,
    'filter': filter,
    'query': query,
    'plan': plan == null ? null : encodePlan(plan!),
    'archive': archive == null ? null : encodeArchive(archive!),
    'cleanup': cleanup == null
        ? null
        : {
            'deleted': cleanup!.deleted,
            'failures': cleanup!.failures,
            'cancelled': cleanup!.cancelled,
            'reclaimedBytes': cleanup!.reclaimedBytes,
            'error': cleanup!.error,
          },
    'restore': restore == null
        ? null
        : {
            'restored': restore!.restored,
            'skipped': restore!.skipped,
            'failures': restore!.failures,
            'cancelled': restore!.cancelled,
            'error': restore!.error,
          },
  };

  factory TaskSnapshot.fromJson(Object? data) {
    final j = jsonMap(data);
    if (j['version'] != 1) throw const FormatException('任务版本不支持');
    final c = j['cleanup'] == null ? null : jsonMap(j['cleanup']);
    final r = j['restore'] == null ? null : jsonMap(j['restore']);
    final snapshot = TaskSnapshot(
      id: j['id'] as String,
      updatedAt: DateTime.parse(j['updatedAt'] as String),
      jpgRoot: j['jpgRoot'] as String?,
      rawRoot: j['rawRoot'] as String?,
      outputRoot: j['outputRoot'] as String?,
      plan: j['plan'] == null ? null : decodePlan(j['plan']),
      archive: j['archive'] == null ? null : decodeArchive(j['archive']),
      cleanup: c == null
          ? null
          : CleanupResult(
              deleted: List<String>.from(c['deleted']),
              failures: Map<String, String>.from(c['failures']),
              cancelled: c['cancelled'] as bool,
              reclaimedBytes: c['reclaimedBytes'] as int,
              error: c['error'] as String?,
            ),
      restore: r == null
          ? null
          : RestoreResult(
              restored: Map<String, String>.from(r['restored']),
              skipped: List<String>.from(r['skipped']),
              failures: Map<String, String>.from(r['failures']),
              cancelled: r['cancelled'] as bool,
              error: r['error'] as String?,
            ),
      bookmarks: Map<String, String>.from(j['bookmarks'] ?? {}),
      selectedIndex: j['selectedIndex'] as int?,
      filter: j['filter'] as String? ?? '全部',
      query: j['query'] as String? ?? '',
      phase: j['phase'] as String? ?? 'idle',
    );
    validateSnapshot(snapshot);
    return snapshot;
  }
}

PhotoFile decodePhoto(Object? data) {
  final j = jsonMap(data);
  return PhotoFile(
    path: j['path'] as String,
    relativePath: j['relativePath'] as String,
    size: j['size'] as int,
    modifiedMicros: j['modifiedMicros'] as int,
  );
}

ArchiveReceipt decodeReceipt(Object? data) {
  final j = jsonMap(data);
  return ArchiveReceipt(
    source: decodePhoto(j['source']),
    kind: PhotoKind.values.byName(j['kind'] as String),
    destinationRelativePath: j['destination'] as String,
    sha256: j['sha256'] as String,
  );
}

Map<String, Object?> encodePlan(MatchPlan plan) => {
  'jpgRoot': plan.jpgRoot,
  'rawRoot': plan.rawRoot,
  'rawCount': plan.rawCount,
  'items': plan.items
      .map(
        (i) => {
          'jpg': i.jpg.toJson(),
          'candidates': i.candidates.map((f) => f.toJson()).toList(),
          'chosenPath': i.chosenPath,
        },
      )
      .toList(),
};
MatchPlan decodePlan(Object? data) {
  final j = jsonMap(data);
  return MatchPlan(
    jpgRoot: j['jpgRoot'] as String,
    rawRoot: j['rawRoot'] as String,
    rawCount: j['rawCount'] as int,
    items: List.unmodifiable(
      (j['items'] as List).map((data) {
        final item = jsonMap(data);
        return MatchItem(
          jpg: decodePhoto(item['jpg']),
          candidates: List.unmodifiable(
            (item['candidates'] as List).map(decodePhoto),
          ),
          chosenPath: item['chosenPath'] as String?,
        );
      }),
    ),
  );
}

Map<String, Object?> encodeArchive(ExportResult a) => {
  'directory': a.directory,
  'copied': a.copied,
  'copiedJpg': a.copiedJpg,
  'failures': a.failures,
  'cancelled': a.cancelled,
  'total': a.total,
  'jpgTotal': a.jpgTotal,
  'reportError': a.reportError,
  'includesJpg': a.includesJpg,
  'receipts': a.receipts.map((r) => r.toJson()).toList(),
};
ExportResult decodeArchive(Object? data) {
  final j = jsonMap(data);
  return ExportResult(
    directory: j['directory'] as String,
    copied: List<String>.from(j['copied']),
    copiedJpg: List<String>.from(j['copiedJpg']),
    failures: Map<String, String>.from(j['failures']),
    cancelled: j['cancelled'] as bool,
    total: j['total'] as int,
    jpgTotal: j['jpgTotal'] as int,
    reportError: j['reportError'] as String?,
    includesJpg: j['includesJpg'] as bool,
    receipts: List.unmodifiable((j['receipts'] as List).map(decodeReceipt)),
  );
}

void validateRelative(String relative) {
  if (relative.isEmpty ||
      p.isAbsolute(relative) ||
      p.normalize(relative) != relative ||
      p.split(relative).any((part) => part == '..' || part == '.')) {
    throw const FormatException('任务中包含无效文件路径');
  }
}

void validatePhoto(PhotoFile file, String root) {
  validateRelative(file.relativePath);
  if (!p.isAbsolute(root) ||
      !p.equals(file.path, p.join(root, file.relativePath)) ||
      !p.isWithin(root, file.path) ||
      file.size < 0 ||
      file.modifiedMicros < 0) {
    throw const FormatException('任务文件超出来源目录或记录无效');
  }
}

void validateSnapshot(TaskSnapshot task) {
  if (!RegExp(r'^[a-z0-9_-]{1,100}$').hasMatch(task.id)) {
    throw const FormatException('无效任务标识');
  }
  for (final root in [task.jpgRoot, task.rawRoot, task.outputRoot]) {
    if (root != null && (!p.isAbsolute(root) || p.normalize(root) != root)) {
      throw const FormatException('无效目录路径');
    }
  }
  final plan = task.plan;
  if (task.selectedIndex != null && task.selectedIndex! < 0) {
    throw const FormatException('照片选择记录无效');
  }
  if (plan == null) {
    if (task.archive != null) throw const FormatException('归档缺少匹配计划');
    return;
  }
  if (!p.equals(task.jpgRoot!, plan.jpgRoot) ||
      !p.equals(task.rawRoot!, plan.rawRoot)) {
    throw const FormatException('任务来源不一致');
  }
  for (final item in plan.items) {
    validatePhoto(item.jpg, plan.jpgRoot);
    for (final raw in item.candidates) {
      validatePhoto(raw, plan.rawRoot);
    }
    if (item.chosenPath != null &&
        !item.candidates.any((f) => f.path == item.chosenPath)) {
      throw const FormatException('重名选择记录无效');
    }
  }
  final archive = task.archive;
  if (archive == null) return;
  if (task.outputRoot == null ||
      !p.isWithin(task.outputRoot!, archive.directory) ||
      p.isWithin(plan.jpgRoot, archive.directory) ||
      p.isWithin(plan.rawRoot, archive.directory) ||
      p.equals(plan.jpgRoot, archive.directory) ||
      p.equals(plan.rawRoot, archive.directory)) {
    throw const FormatException('无效归档位置');
  }
  final known = {
    for (final file in [
      ...plan.selected,
      ...plan.items.where((i) => i.raw != null).map((i) => i.jpg),
    ])
      file.path: file,
  };
  final receiptPaths = <String>{};
  for (final receipt in archive.receipts) {
    final root = receipt.kind == PhotoKind.raw ? plan.rawRoot : plan.jpgRoot;
    validatePhoto(receipt.source, root);
    validateRelative(receipt.destinationRelativePath);
    final original = known[receipt.source.path];
    if (original == null ||
        original.size != receipt.source.size ||
        original.modifiedMicros != receipt.source.modifiedMicros ||
        receipt.destinationRelativePath !=
            p.join(
              receipt.kind == PhotoKind.raw ? 'RAW' : 'JPG',
              receipt.source.relativePath,
            ) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(receipt.sha256) ||
        !receiptPaths.add(receipt.source.path)) {
      throw const FormatException('归档凭据与任务不一致');
    }
  }
  if (task.cleanup != null &&
      !task.cleanup!.deleted.every(receiptPaths.contains)) {
    throw const FormatException('清理记录超出归档范围');
  }
  for (final entry
      in task.restore?.restored.entries ?? <MapEntry<String, String>>[]) {
    if (!receiptPaths.contains(entry.key) ||
        !p.equals(p.dirname(entry.key), p.dirname(entry.value))) {
      throw const FormatException('恢复记录超出原目录');
    }
  }
}
