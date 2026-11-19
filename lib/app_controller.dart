import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'core/cleanup.dart';
import 'core/converter.dart';
import 'core/archive_import.dart';
import 'core/exporter.dart';
import 'core/matcher.dart';
import 'core/models.dart';
import 'core/restorer.dart';
import 'core/task_recovery.dart';
import 'core/task_snapshot.dart';
import 'core/task_store.dart';
import 'platform/folder_access.dart';

enum TaskPhase {
  idle,
  loading,
  scanning,
  review,
  copying,
  cleaning,
  restoring,
  converting,
  finished,
}

class PickerController extends ChangeNotifier {
  PickerController({this.store, this.folderAccess});
  final TaskStore? store;
  final FolderAccess? folderAccess;
  String currentTaskId = taskId();
  String? jpgRoot, rawRoot, outputRoot;
  MatchPlan? plan;
  ExportResult? result;
  CleanupResult? cleanup;
  RestoreResult? restoration;
  ConversionResult? conversion;
  CopyProgress? progress;
  Future<void> Function()? closePreviews;
  String? error;
  String scanMessage = '';
  TaskPhase phase = TaskPhase.idle;
  CancellationToken? _token;
  final Map<String, String> _bookmarks = {};
  TaskLease? _lease;
  String? _leaseId;
  bool _disposed = false, _recoveryBlocked = false;
  Future<void> _saveQueue = Future.value();
  Future<void>? _operationDone;
  Timer? _viewSaveTimer;
  int? selectedIndex;
  String filter = '全部', query = '';

  bool get busy => {
    TaskPhase.loading,
    TaskPhase.scanning,
    TaskPhase.copying,
    TaskPhase.cleaning,
    TaskPhase.restoring,
    TaskPhase.converting,
  }.contains(phase);
  bool get locked => busy || result != null;
  bool get canScan =>
      !busy && !_recoveryBlocked && jpgRoot != null && rawRoot != null;
  bool get canExport {
    if (busy || _recoveryBlocked || plan == null || outputRoot == null) {
      return false;
    }
    if (result == null) return true;
    final completed = result!.receipts.map((r) => r.source.path).toSet();
    return result!.cancelled ||
        result!.failures.isNotEmpty ||
        result!.reportError != null ||
        plan!.selected.any((r) => !completed.contains(r.path)) ||
        plan!.items.any(
          (i) => i.raw != null && !completed.contains(i.jpg.path),
        );
  }

  Set<String> get removedSources => snapshot.removedSources;
  CleanupPreview get cleanupPreview =>
      plan == null || result == null || _recoveryBlocked
      ? const CleanupPreview(targets: [], blockedGroups: 0)
      : SourceCleanup().preview(plan!, result!, alreadyDeleted: removedSources);
  bool get canClean => !busy && cleanupPreview.targets.isNotEmpty;
  bool get canRestore =>
      !busy &&
      !_recoveryBlocked &&
      result != null &&
      SourceRestorer().targets(snapshot).isNotEmpty;
  bool canChoose(int? index) =>
      !busy &&
      index != null &&
      plan != null &&
      index < plan!.items.length &&
      !(result?.receipts.any(
            (r) => r.source.path == plan!.items[index].jpg.path,
          ) ??
          false);
  bool get cancellationRequested => _token?.cancelled ?? false;

  TaskSnapshot get snapshot => TaskSnapshot(
    id: currentTaskId,
    updatedAt: DateTime.now(),
    jpgRoot: jpgRoot,
    rawRoot: rawRoot,
    outputRoot: outputRoot,
    plan: plan,
    archive: result,
    cleanup: cleanup,
    restore: restoration,
    bookmarks: Map.of(_bookmarks),
    selectedIndex: selectedIndex,
    filter: filter,
    query: query,
    phase: phase.name,
  );

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _autoSave() {
    unawaited(
      saveNow().catchError((Object exception) {
        error = '任务未保存：${_describe(exception)}';
        _emit();
      }),
    );
  }

  Future<void> saveNow() {
    _viewSaveTimer?.cancel();
    if (store == null ||
        (jpgRoot == null && rawRoot == null && outputRoot == null)) {
      return _saveQueue;
    }
    final state = snapshot;
    final pending = _saveQueue.catchError((Object _) {}).then((_) async {
      if (_leaseId != state.id) {
        await _lease?.close();
        _lease = await store!.acquire(state.id);
        _leaseId = state.id;
      }
      await store!.save(state);
    });
    _saveQueue = pending;
    return pending;
  }

  Future<void> initialize() async {
    if (store == null) return;
    phase = TaskPhase.loading;
    _emit();
    try {
      final id = await store!.currentId();
      phase = TaskPhase.idle;
      if (id != null) await openTask(id);
    } catch (exception) {
      phase = TaskPhase.idle;
      error = '任务未载入：${_describe(exception)}';
    }
    _emit();
  }

  Future<List<TaskSummary>> history() async {
    await saveNow();
    return store?.list() ?? Future.value([]);
  }

  Future<void> openTask(String id) async {
    if (busy) return;
    await saveNow();
    final done = Completer<void>();
    _operationDone = done.future;
    final token = _token = CancellationToken();
    phase = TaskPhase.loading;
    error = null;
    _emit();
    try {
      final loaded = await store!.load(id);
      if (_leaseId != id) {
        final nextLease = await store!.acquire(id);
        await _lease?.close();
        _lease = nextLease;
        _leaseId = id;
      }
      _apply(loaded);
      phase = TaskPhase.loading;
      _recoveryBlocked = false;
      if (folderAccess != null) {
        for (final entry in loaded.bookmarks.entries) {
          final path = _rootFor(entry.key);
          if (path != null) await folderAccess!.restore(path, entry.value);
        }
      }
      final recovered = await TaskRecovery().recover(
        loaded,
        cancellation: token,
      );
      _apply(recovered);
      phase = plan == null
          ? TaskPhase.idle
          : result == null
          ? TaskPhase.review
          : TaskPhase.finished;
      await saveNow();
    } catch (exception) {
      _recoveryBlocked = true;
      phase = TaskPhase.finished;
      error = '任务未就绪：${_describe(exception)}';
    }
    _token = null;
    done.complete();
    _operationDone = null;
    _emit();
  }

  Future<void> keepFolderGrants(Set<String> kinds) async {
    _bookmarks.removeWhere((kind, _) => !kinds.contains(kind));
    await saveNow();
  }

  Future<void> openArchive(String path) async {
    if (busy) return;
    await saveNow();
    final state = await importArchive(path);
    // Access to the parent is not implied by selecting the archive itself.
    // Save the selected archive bookmark separately and request source roots
    // only when a user needs to clean or restore them.
    final archiveBookmark = await folderAccess?.remember(
      state.archive!.directory,
    );
    await _lease?.close();
    _lease = null;
    _leaseId = null;
    _apply(state);
    _bookmarks.clear();
    if (archiveBookmark != null) _bookmarks['ARCHIVE'] = archiveBookmark;
    try {
      _apply(await TaskRecovery().recover(snapshot));
      _recoveryBlocked = false;
    } catch (exception) {
      _recoveryBlocked = true;
      error = _describe(exception);
    }
    phase = TaskPhase.finished;
    await saveNow();
    _emit();
  }

  void _apply(TaskSnapshot state) {
    currentTaskId = state.id;
    jpgRoot = state.jpgRoot;
    rawRoot = state.rawRoot;
    outputRoot = state.outputRoot;
    plan = state.plan;
    result = state.archive;
    cleanup = state.cleanup;
    restoration = state.restore;
    conversion = null;
    _bookmarks
      ..clear()
      ..addAll(state.bookmarks);
    filter = state.filter;
    query = state.query;
    selectedIndex = state.selectedIndex;
    if (plan != null &&
        (selectedIndex == null || selectedIndex! >= plan!.items.length)) {
      selectedIndex = plan!.items.isEmpty ? null : 0;
    }
    progress = null;
  }

  String? _rootFor(String kind) => switch (kind) {
    'JPG' => jpgRoot,
    'RAW' => rawRoot,
    'ARCHIVE' => result?.directory,
    _ => outputRoot,
  };

  Future<void> selectFolder(
    String kind,
    String path, {
    bool reauthorize = false,
  }) async {
    final resolved = await canonicalDirectory(path);
    if (reauthorize && !p.equals(resolved, _rootFor(kind) ?? '')) {
      throw const FormatException('请选择任务原来的目录');
    }
    final bookmark = await folderAccess?.remember(resolved);
    if (bookmark != null) _bookmarks[kind] = bookmark;
    if (reauthorize) {
      await saveNow();
      return;
    }
    if (kind == 'JPG') {
      setSource(jpg: resolved);
    } else if (kind == 'RAW') {
      setSource(raw: resolved);
    } else {
      setOutput(resolved);
    }
  }

  void setSource({String? jpg, String? raw}) {
    if (locked) return;
    if (jpg != null) jpgRoot = p.normalize(jpg);
    if (raw != null) rawRoot = p.normalize(raw);
    plan = null;
    result = null;
    cleanup = null;
    restoration = null;
    conversion = null;
    error = null;
    phase = TaskPhase.idle;
    selectedIndex = null;
    _emit();
    _autoSave();
  }

  void setOutput(String path) {
    if (locked) return;
    outputRoot = p.normalize(path);
    error = null;
    _emit();
    _autoSave();
  }

  void choose(int index, String? path) {
    if (!canChoose(index)) return;
    plan = plan!.choose(index, path);
    phase = TaskPhase.review;
    _emit();
    _autoSave();
  }

  void updateView({int? selected, String? status, String? search}) {
    if (selected != null) selectedIndex = selected;
    if (status != null) filter = status;
    if (search != null) query = search;
    _emit();
    if (store == null) return;
    _viewSaveTimer?.cancel();
    _viewSaveTimer = Timer(const Duration(milliseconds: 200), _autoSave);
  }

  void cancel() {
    _token?.cancelled = true;
    _emit();
  }

  Future<void> _run(
    TaskPhase running,
    Future<void> Function(CancellationToken) action,
  ) async {
    final done = Completer<void>();
    _operationDone = done.future;
    final token = _token = CancellationToken();
    phase = running;
    error = null;
    progress = null;
    _emit();
    try {
      await saveNow();
      await action(token);
    } on TaskCancelled {
      /* safe checkpoint is persisted below */
    } catch (exception) {
      error = _describe(exception);
    } finally {
      phase = plan == null
          ? TaskPhase.idle
          : result == null
          ? TaskPhase.review
          : TaskPhase.finished;
      _token = null;
      try {
        await saveNow();
      } catch (exception) {
        error = '任务未保存：${_describe(exception)}';
      }
      done.complete();
      _operationDone = null;
      _emit();
    }
  }

  Future<void> scan() async {
    if (!canScan) return;
    final previous = plan;
    await _run(TaskPhase.scanning, (token) async {
      scanMessage = '匹配中…';
      final fresh = await PhotoMatcher().scan(
        jpgRoot: jpgRoot!,
        rawRoot: rawRoot!,
        token: token,
        allowEmpty: result != null,
        onProgress: (label, count) {
          scanMessage = '$label · $count';
          _emit();
        },
      );
      jpgRoot = fresh.jpgRoot;
      rawRoot = fresh.rawRoot;
      if (previous == null || result == null) {
        plan = fresh;
      } else {
        final completed = result!.receipts.map((r) => r.source.path).toSet();
        final merged = {for (final item in fresh.items) item.jpg.path: item};
        for (final old in previous.items) {
          if (completed.contains(old.jpg.path)) {
            merged[old.jpg.path] = old;
          } else if (old.chosenPath != null &&
              (merged[old.jpg.path]?.candidates.any(
                    (r) => r.path == old.chosenPath,
                  ) ??
                  false)) {
            merged[old.jpg.path] = merged[old.jpg.path]!.choose(old.chosenPath);
          }
        }
        final items = merged.values.toList()
          ..sort((a, b) => a.jpg.relativePath.compareTo(b.jpg.relativePath));
        plan = MatchPlan(
          jpgRoot: fresh.jpgRoot,
          rawRoot: fresh.rawRoot,
          items: items,
          rawCount: fresh.rawCount,
        );
      }
      selectedIndex = plan!.items.isEmpty
          ? null
          : (selectedIndex ?? 0).clamp(0, plan!.items.length - 1);
    });
  }

  Future<void> export() async {
    if (!canExport) return;
    final previous = result;
    await _run(TaskPhase.copying, (token) async {
      if (previous == null) outputRoot = await canonicalDirectory(outputRoot!);
      final watch = Stopwatch()..start();
      result = await RawExporter().export(
        plan: plan!,
        outputRoot: outputRoot!,
        token: token,
        verifyHash: true,
        includeJpg: true,
        resume: previous,
        removedSources: removedSources,
        onBatchReady: (checkpoint) async {
          result = checkpoint;
          await saveNow();
        },
        onProgress: (value) {
          progress = value;
          if (watch.elapsedMilliseconds >= 80 ||
              value.completed == value.total ||
              value.verifying) {
            watch.reset();
            _emit();
          }
        },
      );
    });
  }

  Future<void> cleanSources() async {
    if (!canClean) return;
    await _run(TaskPhase.cleaning, (token) async {
      final latest = await SourceCleanup().clean(
        plan: plan!,
        archive: result!,
        token: token,
        alreadyDeleted: removedSources,
        onProgress: (value) {
          progress = value;
          _emit();
        },
      );
      final deleted = {...?cleanup?.deleted, ...latest.deleted};
      // A cleaned source that has just been restored and cleaned again is no
      // longer a completed restoration.
      final restored = {...?restoration?.restored}
        ..removeWhere((key, value) => latest.deleted.contains(key));
      if (restoration != null) {
        restoration = RestoreResult(
          restored: restored,
          skipped: [],
          failures: {},
          cancelled: false,
        );
      }
      cleanup = CleanupResult(
        deleted: deleted.toList(),
        failures: latest.failures,
        cancelled: latest.cancelled,
        reclaimedBytes: deleted.fold(
          0,
          (sum, path) =>
              sum +
              (result!.receipts
                      .where((r) => r.source.path == path)
                      .firstOrNull
                      ?.source
                      .size ??
                  0),
        ),
        error: latest.error,
      );
    });
  }

  Future<void> convertImages(
    ConversionRequest request, {
    bool selectedOnly = false,
    RawDecoder? decoder,
  }) async {
    if (busy) return;
    conversion = null;
    await _run(TaskPhase.converting, (token) async {
      List<ConversionSource>? sources;
      if (selectedOnly) {
        if (plan == null || plan!.selected.isEmpty) {
          throw const FormatException('没有已匹配的精选 RAW');
        }
        final receipts = {
          for (final receipt in result?.receipts ?? <ArchiveReceipt>[])
            if (receipt.kind == PhotoKind.raw) receipt.source.path: receipt,
        };
        sources = [];
        for (final raw in plan!.selected) {
          token.check();
          final receipt = receipts[raw.path];
          if (receipt == null) {
            sources.add(ConversionSource(raw, plan!.rawRoot));
          } else {
            final path = p.join(
              result!.directory,
              receipt.destinationRelativePath,
            );
            final stat = await File(path).stat();
            sources.add(
              ConversionSource(
                PhotoFile(
                  path: path,
                  relativePath: raw.relativePath,
                  size: raw.size,
                  modifiedMicros: stat.modified.microsecondsSinceEpoch,
                ),
                p.join(result!.directory, 'RAW'),
                expectedHash: receipt.sha256,
              ),
            );
          }
        }
      }
      conversion = await RawImageConverter(decoder: decoder).convert(
        request: ConversionRequest(
          outputRoot: request.outputRoot,
          inputRoot: request.inputRoot,
          sources: sources ?? request.sources,
          format: request.format,
          quality: request.quality,
        ),
        token: token,
        onProgress: (value) {
          progress = value;
          _emit();
        },
      );
    });
  }

  Future<RestorePreview> prepareRestore() =>
      SourceRestorer().preview(snapshot, CancellationToken());
  Future<void> restoreSources(Map<String, ConflictAction> conflicts) async {
    if (!canRestore) return;
    await _run(TaskPhase.restoring, (token) async {
      final latest = await SourceRestorer().restore(
        task: snapshot,
        token: token,
        conflicts: conflicts,
        onProgress: (value) {
          progress = value;
          _emit();
        },
      );
      restoration = RestoreResult(
        restored: {...?restoration?.restored, ...latest.restored},
        skipped: latest.skipped,
        failures: latest.failures,
        cancelled: latest.cancelled,
        error: latest.error,
      );
    });
  }

  Future<void> newTask() async {
    if (busy) return;
    await saveNow();
    await _lease?.close();
    _lease = null;
    _leaseId = null;
    await store?.setCurrent(null);
    currentTaskId = taskId();
    jpgRoot = null;
    rawRoot = null;
    outputRoot = null;
    plan = null;
    result = null;
    cleanup = null;
    restoration = null;
    conversion = null;
    progress = null;
    error = null;
    _bookmarks.clear();
    selectedIndex = null;
    filter = '全部';
    query = '';
    _recoveryBlocked = false;
    phase = TaskPhase.idle;
    _emit();
  }

  Future<bool> prepareToClose() async {
    _token?.cancelled = true;
    await _operationDone;
    try {
      await closePreviews?.call();
      await saveNow();
      await _lease?.close();
      _lease = null;
      _leaseId = null;
      return true;
    } catch (exception) {
      error = '任务未保存：${_describe(exception)}';
      _emit();
      return false;
    }
  }

  String _describe(Object exception) => switch (exception) {
    FormatException e => e.message,
    FileSystemException e =>
      '${e.message}${e.path == null ? '' : '\n${e.path}'}',
    _ => exception.toString(),
  };
  @override
  void dispose() {
    _viewSaveTimer?.cancel();
    _disposed = true;
    _token?.cancelled = true;
    unawaited(_lease?.close());
    super.dispose();
  }
}
