import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'core/culling.dart';
import 'core/matcher.dart';
import 'core/models.dart';
import 'core/task_snapshot.dart';
import 'platform/folder_access.dart';

class CullingController extends ChangeNotifier {
  CullingController({this.preferences, this.folderAccess});
  final File? preferences;
  final FolderAccess? folderAccess;
  CullingSession? session;
  CullingStore? _store;
  CancellationToken? _token;
  Future<void>? _operation;
  Future<void> Function()? closePreviews;
  final _undo = <(String, PickDecision?, int)>[];
  bool busy = false, sorting = false, _disposed = false;
  String? error, bookmark;
  String filter = '全部';
  int completed = 0, total = 0;
  String currentFile = '';
  Timer? _saveTimer;

  static Future<CullingController> open() async => CullingController(
    preferences: File(
      p.join(
        (await getApplicationSupportDirectory()).path,
        'culling-v1',
        'current.json',
      ),
    ),
    folderAccess: FolderAccess(),
  );

  bool get canDecide => !busy && session != null && !session!.started;
  bool get canUndo => canDecide && _undo.isNotEmpty;
  bool get canSort =>
      !busy &&
      session != null &&
      !session!.finished &&
      session!.processed == session!.plan.items.length &&
      session!.conflicts == 0;
  MatchItem? get current =>
      session == null ? null : session!.plan.items[session!.index];
  List<int> get visible => session == null
      ? []
      : [
          for (var i = 0; i < session!.plan.items.length; i++)
            if (filter == '全部' ||
                (filter == '未决定' &&
                    session!.decisions[session!.plan.items[i].jpg.path] ==
                        null) ||
                (filter == '保留' &&
                    session!.decisions[session!.plan.items[i].jpg.path] ==
                        PickDecision.keep) ||
                (filter == '不要' &&
                    session!.decisions[session!.plan.items[i].jpg.path] ==
                        PickDecision.reject))
              i,
        ];
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (preferences == null || !await preferences!.exists()) return;
    try {
      final saved = jsonMap(jsonDecode(await preferences!.readAsString()));
      final path = saved['root'] as String;
      final grant = saved['bookmark'] as String?;
      if (grant != null) await folderAccess?.restore(path, grant);
      await openSource(path);
    } catch (exception) {
      error = '目录未载入，请重新选择源文件夹：${_describe(exception)}';
      _emit();
    }
  }

  Future<void> openSource(String path) async {
    if (busy) return;
    await _run(false, (token) async {
      final root = await canonicalDirectory(path);
      if (_store != null && session?.root == root) {
        bookmark = await folderAccess?.remember(root);
        await _remember();
        return;
      }
      await saveNow();
      final grant = await folderAccess?.remember(root);
      final nextStore = await CullingStore.open(root);
      try {
        final next =
            await nextStore.load() ?? await scanCullingFolder(root, token);
        await CullingOrganizer().recover(next, nextStore, token);
        await nextStore.save(next);
        await _store?.close();
        _store = nextStore;
        session = next;
        bookmark = grant;
        filter = '全部';
        _undo.clear();
        await _remember();
      } catch (_) {
        if (_store != nextStore) await nextStore.close();
        rethrow;
      }
    });
  }

  Future<void> rescan() async {
    if (busy || session == null || session!.started) return;
    await _run(false, (token) async {
      final old = session!;
      final next = await scanCullingFolder(old.root, token);
      for (var i = 0; i < next.plan.items.length; i++) {
        final item = next.plan.items[i];
        final previous = old.plan.items
            .where((j) => j.jpg.path == item.jpg.path)
            .firstOrNull;
        if (previous == null ||
            previous.jpg.size != item.jpg.size ||
            previous.jpg.modifiedMicros != item.jpg.modifiedMicros) {
          continue;
        }
        if (old.decisions.containsKey(item.jpg.path)) {
          next.decisions[item.jpg.path] = old.decisions[item.jpg.path]!;
        }
        if (old.skippedRaw.contains(item.jpg.path)) {
          next.skippedRaw.add(item.jpg.path);
        }
        if (previous.chosenPath != null &&
            item.candidates.any((r) => r.path == previous.chosenPath)) {
          next.plan = next.plan.choose(i, previous.chosenPath);
        }
      }
      session = next;
      _undo.clear();
      await saveNow();
    });
  }

  void select(int index) {
    if (busy ||
        session == null ||
        index < 0 ||
        index >= session!.plan.items.length) {
      return;
    }
    session!.index = index;
    _emit();
    _scheduleSave();
  }

  void next(int delta) {
    final indices = visible;
    if (indices.isEmpty) return;
    final position = indices.indexOf(session!.index);
    select(indices[(position + delta).clamp(0, indices.length - 1)]);
  }

  void setFilter(String value) {
    filter = value;
    final indices = visible;
    if (indices.isNotEmpty && !indices.contains(session?.index)) {
      session!.index = indices.first;
      _scheduleSave();
    }
    _emit();
  }

  void decide(PickDecision value) {
    if (!canDecide) return;
    final state = session!, path = current!.jpg.path;
    final previous = state.decisions[path];
    if (previous != value) _undo.add((path, previous, state.index));
    state.decisions[path] = value;
    if (filter == '未决定' && state.processed == state.plan.items.length) {
      filter = '全部';
    }
    if (filter == '全部' || filter == '未决定') {
      for (var offset = 1; offset < state.plan.items.length; offset++) {
        final index = (state.index + offset) % state.plan.items.length;
        if (!state.decisions.containsKey(state.plan.items[index].jpg.path)) {
          state.index = index;
          break;
        }
      }
    }
    if (filter == '保留' || filter == '不要') {
      final indices = visible;
      if (indices.isNotEmpty && !indices.contains(state.index)) {
        state.index =
            indices.where((i) => i > state.index).firstOrNull ?? indices.last;
      }
    }
    _emit();
    _scheduleSave();
  }

  void undo() {
    if (!canUndo) return;
    final (path, previous, index) = _undo.removeLast();
    if (previous == null) {
      session!.decisions.remove(path);
    } else {
      session!.decisions[path] = previous;
    }
    session!.index = index;
    filter = '全部';
    _emit();
    _scheduleSave();
  }

  void chooseRaw(String? path) {
    if (!canDecide || current == null) return;
    final state = session!, item = current!;
    if (path == null) {
      state.skippedRaw.add(item.jpg.path);
      state.plan = state.plan.choose(state.index, null);
    } else {
      state.skippedRaw.remove(item.jpg.path);
      state.plan = state.plan.choose(state.index, path);
    }
    _emit();
    _scheduleSave();
  }

  Future<void> organize() async {
    if (!canSort) return;
    await _run(true, (token) async {
      await closePreviews?.call();
      await saveNow();
      await CullingOrganizer().organize(
        session!,
        _store!,
        token,
        onProgress: (done, count, file) {
          completed = done;
          total = count;
          currentFile = file;
          _emit();
        },
      );
    });
    try {
      await saveNow();
    } catch (exception) {
      error = _describe(exception);
      _emit();
    }
  }

  void cancel() {
    _token?.cancelled = true;
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 100), () {
      unawaited(
        saveNow().catchError((Object e) {
          error = '选片未保存：${_describe(e)}';
          _emit();
        }),
      );
    });
  }

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    if (session != null) {
      _store ??= await CullingStore.open(session!.root);
      await _store!.save(session!);
    }
  }

  Future<void> _remember() async {
    if (preferences == null || session == null) return;
    await preferences!.parent.create(recursive: true);
    final temporary = File('${preferences!.path}.${taskId()}.tmp');
    await temporary.writeAsString(
      jsonEncode({'root': session!.root, 'bookmark': bookmark}),
      flush: true,
    );
    await temporary.rename(preferences!.path);
  }

  Future<void> _run(
    bool moving,
    Future<void> Function(CancellationToken) action,
  ) async {
    final done = Completer<void>();
    _operation = done.future;
    final token = _token = CancellationToken();
    busy = true;
    sorting = moving;
    error = null;
    completed = 0;
    total = 0;
    _emit();
    try {
      await action(token);
    } on TaskCancelled {
      /* completed moves remain in the durable journal */
    } catch (exception) {
      error = _describe(exception);
    } finally {
      busy = false;
      sorting = false;
      _token = null;
      _operation = null;
      done.complete();
      _emit();
    }
  }

  Future<bool> prepareToClose() async {
    _token?.cancelled = true;
    await _operation;
    try {
      await closePreviews?.call();
      await saveNow();
      await _store?.close();
      _store = null;
      return true;
    } catch (exception) {
      error = _describe(exception);
      _emit();
      return false;
    }
  }

  String _describe(Object error) => error is FormatException
      ? error.message
      : error is FileSystemException
      ? '${error.message}${error.path == null ? '' : '\n${error.path}'}'
      : '$error';
  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    _token?.cancelled = true;
    unawaited(_store?.close());
    super.dispose();
  }
}
