import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unicode;
import 'atomic_commit.dart';
import 'integrity.dart';
import 'matcher.dart';
import 'models.dart';
import 'task_snapshot.dart';
import 'task_store.dart';

enum PickDecision { keep, reject }

const pickedRawFolder = '已选 RAW';
const rejectedRawFolder = '未选 RAW';
const allJpgFolder = 'JPG';
const _metadataFolder = '.拾片选片';

String _pathKey(String value) => unicode.nfc(value).toLowerCase();
String _mediaRelative(String value) {
  final parts = p.split(value);
  if (parts.length > 1 &&
      {
        pickedRawFolder,
        rejectedRawFolder,
        allJpgFolder,
      }.contains(parts.first)) {
    return p.joinAll(parts.skip(1));
  }
  return value;
}

class CullMove {
  const CullMove(this.source, this.destination, {this.sha256});
  final PhotoFile source;
  final String destination;
  final String? sha256;
  Map<String, Object?> toJson() => {
    'source': source.toJson(),
    'destination': destination,
    'sha256': sha256,
  };
  factory CullMove.fromJson(Object? value) {
    final j = jsonMap(value);
    return CullMove(
      decodePhoto(j['source']),
      j['destination'] as String,
      sha256: j['sha256'] as String?,
    );
  }
}

class CullingSession {
  CullingSession({
    required this.plan,
    required this.raws,
    Map<String, PickDecision>? decisions,
    Set<String>? skippedRaw,
    this.index = 0,
    this.started = false,
    this.finished = false,
  }) : decisions = decisions ?? {},
       skippedRaw = skippedRaw ?? {};
  MatchPlan plan;
  final List<PhotoFile> raws;
  final Map<String, PickDecision> decisions;
  final Set<String> skippedRaw;
  final Map<String, CullMove> moved = {};
  int index;
  bool started, finished;
  String get root => plan.jpgRoot;
  int get processed => decisions.length;
  int count(PickDecision decision) =>
      decisions.values.where((d) => d == decision).length;
  PhotoFile? rawFor(MatchItem item) =>
      skippedRaw.contains(item.jpg.path) ? null : item.raw;
  int get conflicts => plan.items
      .where(
        (i) =>
            i.status == MatchStatus.conflict &&
            !skippedRaw.contains(i.jpg.path),
      )
      .length;
  int get missing => plan.items
      .where((i) => i.candidates.isEmpty || skippedRaw.contains(i.jpg.path))
      .length;
  Set<String> get usedRaw => {
    for (final item in plan.items)
      if (rawFor(item) != null) rawFor(item)!.path,
  };
  List<PhotoFile> get unmatchedRaw {
    final used = usedRaw;
    return raws.where((r) => !used.contains(r.path)).toList();
  }

  String pathFor(PhotoFile file) => moved[file.path] == null
      ? file.path
      : p.join(root, moved[file.path]!.destination);

  List<CullMove> get moves {
    final chosen = <String, bool>{};
    for (final item in plan.items) {
      final raw = rawFor(item);
      if (raw != null) {
        chosen[raw.path] =
            (chosen[raw.path] ?? false) ||
            decisions[item.jpg.path] == PickDecision.keep;
      }
    }
    return [
      for (final raw in raws)
        if (chosen.containsKey(raw.path))
          CullMove(
            raw,
            p.join(
              chosen[raw.path]! ? pickedRawFolder : rejectedRawFolder,
              _mediaRelative(raw.relativePath),
            ),
          ),
      for (final item in plan.items)
        CullMove(
          item.jpg,
          p.join(allJpgFolder, _mediaRelative(item.jpg.relativePath)),
        ),
    ];
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'plan': encodePlan(plan),
    'raws': raws.map((r) => r.toJson()).toList(),
    'decisions': decisions.map((key, value) => MapEntry(key, value.name)),
    'skippedRaw': skippedRaw.toList(),
    'index': index,
    'started': started,
    'finished': finished,
  };
  factory CullingSession.fromJson(Object? value, String root) {
    final j = jsonMap(value);
    if (j['version'] != 1) throw const FormatException('选片记录版本不支持');
    final session = CullingSession(
      plan: decodePlan(j['plan']),
      raws: (j['raws'] as List).map(decodePhoto).toList(),
      decisions: jsonMap(j['decisions']).map(
        (key, value) =>
            MapEntry(key, PickDecision.values.byName(value as String)),
      ),
      skippedRaw: Set<String>.from(j['skippedRaw'] as List),
      index: j['index'] as int,
      started: j['started'] as bool,
      finished: j['finished'] as bool,
    );
    session.validate(root);
    return session;
  }
  void validate(String expectedRoot) {
    if (!p.equals(root, expectedRoot) ||
        !p.equals(plan.rawRoot, expectedRoot)) {
      throw const FormatException('选片记录属于另一目录');
    }
    validateSnapshot(
      TaskSnapshot(
        id: 'culling',
        updatedAt: DateTime.now(),
        jpgRoot: root,
        rawRoot: root,
        plan: plan,
      ),
    );
    final jpgPaths = <String>{}, rawPaths = <String, PhotoFile>{};
    for (final raw in raws) {
      validatePhoto(raw, root);
      if (!rawExtensions.contains(p.extension(raw.path).toLowerCase()) ||
          rawPaths.containsKey(raw.path)) {
        throw const FormatException('RAW 记录无效');
      }
      rawPaths[raw.path] = raw;
    }
    for (final item in plan.items) {
      if (!{
            '.jpg',
            '.jpeg',
          }.contains(p.extension(item.jpg.path).toLowerCase()) ||
          !jpgPaths.add(item.jpg.path)) {
        throw const FormatException('JPG 记录无效');
      }
      for (final raw in item.candidates) {
        if (rawPaths[raw.path]?.size != raw.size ||
            rawPaths[raw.path]?.modifiedMicros != raw.modifiedMicros) {
          throw const FormatException('RAW 候选记录无效');
        }
      }
    }
    if (decisions.keys.any((key) => !jpgPaths.contains(key)) ||
        skippedRaw.any((key) => !jpgPaths.contains(key)) ||
        index < 0 ||
        index >= plan.items.length ||
        plan.rawCount != raws.length ||
        ((started || finished) &&
            (decisions.length != plan.items.length || conflicts > 0))) {
      throw const FormatException('选片状态无效');
    }
  }
}

Future<CullingSession> scanCullingFolder(
  String directory,
  CancellationToken token,
) async {
  final root = await canonicalDirectory(directory);
  final jpgs = <PhotoFile>[], raws = <PhotoFile>[];
  final pending = [Directory(root)];
  while (pending.isNotEmpty) {
    token.check();
    await for (final entity in pending.removeLast().list(followLinks: false)) {
      token.check();
      final name = p.basename(entity.path);
      if (name.startsWith('.') || name == 'RAW转图片') continue;
      if (entity is Directory) {
        pending.add(entity);
        continue;
      }
      if (entity is! File) continue;
      final extension = p.extension(name).toLowerCase();
      final jpg = {'.jpg', '.jpeg'}.contains(extension);
      if (!jpg && !rawExtensions.contains(extension)) continue;
      final stat = await entity.stat();
      final file = PhotoFile(
        path: entity.path,
        relativePath: p.relative(entity.path, from: root),
        size: stat.size,
        modifiedMicros: stat.modified.microsecondsSinceEpoch,
      );
      (jpg ? jpgs : raws).add(file);
    }
  }
  if (jpgs.isEmpty) throw const FormatException('源文件夹中没有 JPG / JPEG');
  jpgs.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  raws.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  final byName = <String, List<PhotoFile>>{};
  for (final raw in raws) {
    byName.putIfAbsent(nameKey(raw.path), () => []).add(raw);
  }
  final items = <MatchItem>[];
  for (final jpg in jpgs) {
    final candidates = byName[nameKey(jpg.path)] ?? [];
    final parent = _pathKey(p.dirname(_mediaRelative(jpg.relativePath)));
    final local = candidates
        .where(
          (raw) =>
              _pathKey(p.dirname(_mediaRelative(raw.relativePath))) == parent,
        )
        .toList();
    items.add(
      MatchItem(jpg: jpg, candidates: local.isEmpty ? candidates : local),
    );
  }
  return CullingSession(
    plan: MatchPlan(
      jpgRoot: root,
      rawRoot: root,
      items: items,
      rawCount: raws.length,
    ),
    raws: raws,
  );
}

class CullingStore {
  CullingStore._(this.root, this.directory, this.lease);
  final String root;
  final Directory directory;
  final TaskLease lease;
  Future<void> _saves = Future.value();
  File get stateFile => File(p.join(directory.path, '选片状态.json'));
  File get journal => File(p.join(directory.path, '整理记录.jsonl'));
  static Future<CullingStore> open(String root) async {
    final path = p.join(root, _metadataFolder);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await Directory(path).create();
      await File(
        p.join(path, 'owner.json'),
      ).writeAsString('{"app":"shipian-culling","version":1}', flush: true);
    } else if (type != FileSystemEntityType.directory ||
        jsonMap(
              jsonDecode(await File(p.join(path, 'owner.json')).readAsString()),
            )['app'] !=
            'shipian-culling') {
      throw const FormatException('选片记录目录被占用');
    }
    if (!p.equals(await Directory(path).resolveSymbolicLinks(), path)) {
      throw const FormatException('选片记录目录不能是链接');
    }
    final lease = await TaskStore(Directory(path)).acquire('selection');
    return CullingStore._(root, Directory(path), lease);
  }

  Future<CullingSession?> load() async {
    for (final path in [stateFile.path, '${stateFile.path}.bak']) {
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('选片状态不能是链接');
      }
    }
    if (!await stateFile.exists() &&
        !await File('${stateFile.path}.bak').exists()) {
      return null;
    }
    try {
      return CullingSession.fromJson(
        jsonDecode(await stateFile.readAsString()),
        root,
      );
    } catch (_) {
      final backup = File('${stateFile.path}.bak');
      if (!await backup.exists()) rethrow;
      return CullingSession.fromJson(
        jsonDecode(await backup.readAsString()),
        root,
      );
    }
  }

  Future<void> save(CullingSession session) {
    session.validate(root);
    final json = jsonEncode(session.toJson());
    _saves = _saves.catchError((Object _) {}).then((_) async {
      if (await stateFile.exists()) {
        try {
          final previous = await stateFile.readAsString();
          CullingSession.fromJson(jsonDecode(previous), root);
          await _replace(File('${stateFile.path}.bak'), previous);
        } on FormatException {
          /* keep the valid backup */
        }
      }
      await _replace(stateFile, json);
    });
    return _saves;
  }

  Future<void> _replace(File target, String json) async {
    if (await FileSystemEntity.type(target.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('选片记录不能是链接');
    }
    final temporary = File('${target.path}.${taskId()}.tmp');
    await temporary.create(exclusive: true);
    try {
      await temporary.writeAsString(json, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> append(String event, CullMove move) async {
    if (await FileSystemEntity.type(journal.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('整理记录不能是链接');
    }
    await journal.writeAsString(
      '${jsonEncode({'event': event, ...move.toJson()})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<List<CullMove>> readMoves() async {
    if (!await journal.exists()) return [];
    if (await FileSystemEntity.type(journal.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('整理记录无效');
    }
    final bytes = await journal.readAsBytes();
    final end = bytes.lastIndexOf(10) + 1;
    if (end != bytes.length) {
      final file = await journal.open(mode: FileMode.append);
      try {
        await file.truncate(end);
        await file.flush();
      } finally {
        await file.close();
      }
    }
    final result = <String, CullMove>{};
    for (final line in const LineSplitter().convert(
      utf8.decode(bytes.sublist(0, end)),
    )) {
      if (line.trim().isEmpty) continue;
      final json = jsonMap(jsonDecode(line));
      if (json['event'] != 'prepared' && json['event'] != 'moved') {
        throw const FormatException('整理事件无效');
      }
      final move = CullMove.fromJson(json);
      result[move.source.path] = move;
    }
    return result.values.toList();
  }

  Future<void> close() async {
    try {
      await _saves;
    } finally {
      await lease.close();
    }
  }
}

class CullingOrganizer {
  Future<void> recover(
    CullingSession session,
    CullingStore store,
    CancellationToken token,
  ) async {
    final expected = {for (final move in session.moves) move.source.path: move};
    final recorded = await store.readMoves();
    if (!session.started && recorded.isNotEmpty) {
      if (session.processed != session.plan.items.length ||
          session.conflicts > 0) {
        throw const FormatException('整理记录与选片状态不一致');
      }
      // A valid prior snapshot can precede the durable 'started' save. The
      // journal still has to match every planned path and checksum below.
      session.started = true;
    }
    for (final move in recorded) {
      token.check();
      final original = expected[move.source.path];
      if (original == null ||
          original.destination != move.destination ||
          original.source.size != move.source.size ||
          original.source.modifiedMicros != move.source.modifiedMicros ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(move.sha256 ?? '')) {
        throw const FormatException('整理记录与文件不一致');
      }
      validatePhoto(move.source, session.root);
      validateRelative(move.destination);
      final target = p.join(session.root, move.destination);
      await _parent(session.root, p.dirname(move.destination), create: false);
      final sourceType = await FileSystemEntity.type(
        move.source.path,
        followLinks: false,
      );
      final targetType = await FileSystemEntity.type(
        target,
        followLinks: false,
      );
      if (sourceType == FileSystemEntityType.notFound &&
          targetType == FileSystemEntityType.file &&
          p.equals(await File(target).resolveSymbolicLinks(), target) &&
          await hashFile(File(target), token) == move.sha256) {
        session.moved[move.source.path] = move;
      } else if (sourceType == FileSystemEntityType.file &&
          targetType == FileSystemEntityType.notFound) {
        await checkSnapshot(move.source, session.root);
        if (await hashFile(File(move.source.path), token) != move.sha256) {
          throw const FormatException('整理中断后源文件已变化');
        }
      } else {
        throw FileSystemException('整理记录无法核对，请检查源文件和目标文件', move.source.path);
      }
    }
    if (session.started) {
      session.finished = session.moves.every(
        (m) =>
            p.equals(m.source.path, p.join(session.root, m.destination)) ||
            session.moved.containsKey(m.source.path),
      );
    }
  }

  Future<void> organize(
    CullingSession session,
    CullingStore store,
    CancellationToken token, {
    void Function(int, int, String)? onProgress,
  }) async {
    session.validate(session.root);
    if (session.processed != session.plan.items.length ||
        session.conflicts > 0) {
      throw const FormatException('请先处理全部 JPG 和 RAW 重名候选');
    }
    await recover(session, store, token);
    final moves = session.moves;
    final targets = <String>{};
    // Check the whole batch before the first media file is moved.
    for (final move in moves) {
      token.check();
      validateRelative(move.destination);
      if (!targets.add(_pathKey(move.destination))) {
        throw const FormatException('整理后的文件名冲突');
      }
      await _parent(session.root, p.dirname(move.destination), create: false);
      if (session.moved.containsKey(move.source.path)) continue;
      await checkSnapshot(move.source, session.root);
      final target = p.join(session.root, move.destination);
      if (!p.equals(move.source.path, target) &&
          await FileSystemEntity.type(target, followLinks: false) !=
              FileSystemEntityType.notFound) {
        throw FileSystemException('目标已存在，未移动任何新文件', target);
      }
    }
    session.started = true;
    await store.save(session);
    for (final folder in [pickedRawFolder, rejectedRawFolder, allJpgFolder]) {
      await _parent(session.root, folder, create: true);
    }
    var done = 0;
    for (final move in moves) {
      token.check();
      onProgress?.call(done, moves.length, move.source.relativePath);
      final target = p.join(session.root, move.destination);
      if (!session.moved.containsKey(move.source.path) &&
          !p.equals(move.source.path, target)) {
        await checkSnapshot(move.source, session.root);
        final digest = await hashFile(File(move.source.path), token);
        await checkSnapshot(move.source, session.root);
        await _parent(session.root, p.dirname(move.destination), create: true);
        token.check();
        final receipt = CullMove(move.source, move.destination, sha256: digest);
        await store.append('prepared', receipt);
        commitWithoutReplacing(move.source.path, target);
        session.moved[move.source.path] = receipt;
        await store.append('moved', receipt);
      }
      onProgress?.call(++done, moves.length, move.source.relativePath);
    }
    session.finished = true;
    await store.save(session);
  }

  Future<void> _parent(
    String root,
    String relative, {
    required bool create,
  }) async {
    if (relative == '.') return;
    validateRelative(relative);
    var current = root;
    for (final part in p.split(relative)) {
      current = p.join(current, part);
      var type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (!create) return;
        await Directory(current).create();
        type = FileSystemEntityType.directory;
      }
      if (type != FileSystemEntityType.directory ||
          !p.equals(await Directory(current).resolveSymbolicLinks(), current)) {
        throw FileSystemException('目标父目录被占用或包含链接', current);
      }
    }
  }
}
