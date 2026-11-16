import 'package:path/path.dart' as p;

class PhotoFile {
  const PhotoFile({
    required this.path,
    required this.relativePath,
    required this.size,
    required this.modifiedMicros,
  });
  final String path;
  final String relativePath;
  final int size;
  final int modifiedMicros;
  String get name => p.basename(path);
  Map<String, Object> toJson() => {
    'path': path,
    'relativePath': relativePath,
    'size': size,
    'modifiedMicros': modifiedMicros,
  };
}

enum MatchStatus { matched, missing, conflict }

class MatchItem {
  MatchItem({required this.jpg, required this.candidates, this.chosenPath});
  final PhotoFile jpg;
  final List<PhotoFile> candidates;
  final String? chosenPath;
  PhotoFile? get raw {
    if (candidates.length == 1) return candidates.single;
    for (final candidate in candidates) {
      if (candidate.path == chosenPath) return candidate;
    }
    return null;
  }

  MatchStatus get status => raw != null
      ? MatchStatus.matched
      : candidates.isEmpty
      ? MatchStatus.missing
      : MatchStatus.conflict;
  bool get manuallyChosen => candidates.length > 1 && raw != null;
  MatchItem choose(String? path) {
    if (path != null && !candidates.any((c) => c.path == path)) {
      throw ArgumentError('选择的 RAW 不在候选列表中');
    }
    return MatchItem(jpg: jpg, candidates: candidates, chosenPath: path);
  }
}

class MatchPlan {
  MatchPlan({
    required this.jpgRoot,
    required this.rawRoot,
    required this.items,
    required this.rawCount,
  });
  final String jpgRoot;
  final String rawRoot;
  final List<MatchItem> items;
  final int rawCount;
  late final Map<MatchStatus, int> _counts = {
    for (final status in MatchStatus.values)
      status: items.where((i) => i.status == status).length,
  };
  int count(MatchStatus status) => _counts[status]!;
  late final List<PhotoFile> selected = List.unmodifiable(
    ({
        for (final item in items)
          if (item.raw != null) item.raw!.path: item.raw!,
      }.values.toList()
      ..sort((a, b) => a.relativePath.compareTo(b.relativePath))),
  );
  late final int totalBytes = selected.fold(0, (sum, f) => sum + f.size);
  MatchPlan choose(int index, String? path) => MatchPlan(
    jpgRoot: jpgRoot,
    rawRoot: rawRoot,
    rawCount: rawCount,
    items: [
      for (var i = 0; i < items.length; i++)
        i == index ? items[i].choose(path) : items[i],
    ],
  );
}

class TaskCancelled implements Exception {
  @override
  String toString() => '任务已取消';
}

class CancellationToken {
  bool cancelled = false;
  void check() {
    if (cancelled) throw TaskCancelled();
  }
}

class CopyProgress {
  const CopyProgress({
    required this.completed,
    required this.total,
    required this.bytes,
    required this.totalBytes,
    required this.file,
    this.verifying = false,
  });
  final int completed, total, bytes, totalBytes;
  final String file;
  final bool verifying;
  double get fraction => totalBytes == 0 ? 0 : (bytes / totalBytes).clamp(0, 1);
}

class ExportResult {
  const ExportResult({
    required this.directory,
    required this.copied,
    required this.failures,
    required this.cancelled,
    required this.total,
    this.reportError,
    this.copiedJpg = const [],
    this.jpgTotal = 0,
    this.receipts = const [],
    this.includesJpg = false,
  });
  final String directory;
  final List<String> copied;
  final Map<String, String> failures;
  final bool cancelled;
  final int total;
  final String? reportError;
  final List<String> copiedJpg;
  final int jpgTotal;
  final List<ArchiveReceipt> receipts;
  final bool includesJpg;
  int get copiedFileCount => copied.length + copiedJpg.length;
  int get totalFiles => total + jpgTotal;
  bool get complete =>
      !cancelled &&
      failures.isEmpty &&
      reportError == null &&
      copied.length == total &&
      copiedJpg.length == jpgTotal;
}

enum PhotoKind { raw, jpg }

class ArchiveReceipt {
  const ArchiveReceipt({
    required this.source,
    required this.kind,
    required this.destinationRelativePath,
    required this.sha256,
  });
  final PhotoFile source;
  final PhotoKind kind;
  final String destinationRelativePath;
  final String sha256;
  Map<String, Object> toJson() => {
    'source': source.toJson(),
    'kind': kind.name,
    'destination': destinationRelativePath,
    'sha256': sha256,
  };
}

class CleanupPreview {
  const CleanupPreview({required this.targets, required this.blockedGroups});
  final List<ArchiveReceipt> targets;
  final int blockedGroups;
  int get rawCount => targets.where((t) => t.kind == PhotoKind.raw).length;
  int get jpgCount => targets.where((t) => t.kind == PhotoKind.jpg).length;
  int get totalBytes => targets.fold(0, (sum, t) => sum + t.source.size);
}

class CleanupResult {
  const CleanupResult({
    required this.deleted,
    required this.failures,
    required this.cancelled,
    required this.reclaimedBytes,
    this.error,
  });
  final List<String> deleted;
  final Map<String, String> failures;
  final bool cancelled;
  final int reclaimedBytes;
  final String? error;
}

enum ConflictAction { skip, keepBoth }

class RestoreConflict {
  const RestoreConflict({required this.receipt, required this.existingBytes});
  final ArchiveReceipt receipt;
  final int existingBytes;
}

class RestorePreview {
  const RestorePreview({required this.targets, required this.conflicts});
  final List<ArchiveReceipt> targets;
  final List<RestoreConflict> conflicts;
}

class RestoreResult {
  const RestoreResult({
    required this.restored,
    required this.skipped,
    required this.failures,
    required this.cancelled,
    this.error,
  });
  final Map<String, String> restored;
  final List<String> skipped;
  final Map<String, String> failures;
  final bool cancelled;
  final String? error;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var amount = bytes / 1024;
  var index = 0;
  while (amount >= 1024 && index < units.length - 1) {
    amount /= 1024;
    index++;
  }
  return '${amount.toStringAsFixed(amount < 10 ? 1 : 0)} ${units[index]}';
}
