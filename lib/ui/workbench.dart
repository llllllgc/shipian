import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../app_controller.dart';
import '../core/models.dart';
import 'conversion_dialog.dart';
import 'palette.dart';
import 'preview_pane.dart';
import 'results_pane.dart';
import 'task_dialogs.dart';

class Workbench extends StatefulWidget {
  const Workbench({super.key, this.controller});
  final PickerController? controller;
  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> {
  late final PickerController model = widget.controller ?? PickerController();
  int? get selectedIndex => model.selectedIndex;
  String get filter => model.filter;
  String get query => model.query;
  bool picking = false;
  Map<String, String> get archivedJpgs => {
    for (final receipt in model.result?.receipts ?? <ArchiveReceipt>[])
      if (receipt.kind == PhotoKind.jpg)
        receipt.source.path: p.join(
          model.result!.directory,
          receipt.destinationRelativePath,
        ),
  };
  String? get archivedPreview => selectedIndex == null || model.plan == null
      ? null
      : archivedJpgs[model.plan!.items[selectedIndex!].jpg.path];

  @override
  void initState() {
    super.initState();
    model.addListener(_changed);
    // Optional local test fixture; release builds have no synthetic photo library.
    const fixture = String.fromEnvironment('FIXTURE_ROOT');
    if (fixture.isNotEmpty) {
      model.setSource(
        jpg: p.join(fixture, '已选JPG'),
        raw: p.join(fixture, '全部RAW'),
      );
      model.setOutput(p.join(fixture, '导出'));
      WidgetsBinding.instance.addPostFrameCallback((_) => model.scan());
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    if (widget.controller == null) model.dispose();
    super.dispose();
  }

  Future<void> _chooseFolder(String kind) async {
    if (picking || model.locked) return;
    setState(() => picking = true);
    try {
      final path = await getDirectoryPath(confirmButtonText: '选择此文件夹');
      if (path == null || !mounted) return;
      await model.selectFolder(kind, path);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法打开文件夹：$error')));
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> _taskAction(String action) async {
    if (model.busy || picking) return;
    try {
      if (action == 'new') {
        await model.newTask();
      } else if (action == 'history') {
        setState(() => picking = true);
        final tasks = await model.history();
        if (!mounted) return;
        setState(() => picking = false);
        final next = await showTaskHistory(context, tasks);
        if (next == null || !mounted) return;
        if (next.action == 'open') {
          await model.openTask(next.id!);
        } else {
          await _taskAction(next.action);
        }
      } else if (action == 'import') {
        setState(() => picking = true);
        final folder = await getDirectoryPath(confirmButtonText: '打开归档');
        if (folder != null) await model.openArchive(folder);
      } else if (action == 'authorize') {
        setState(() => picking = true);
        for (final entry in {
          'JPG': model.jpgRoot,
          'RAW': model.rawRoot,
          'OUT': model.outputRoot,
        }.entries) {
          if (entry.value == null) continue;
          final folder = await getDirectoryPath(
            initialDirectory: entry.value,
            confirmButtonText:
                '授权 ${entry.key == 'ARCHIVE' ? '归档' : entry.key}',
          );
          if (folder == null) return;
          await model.selectFolder(entry.key, folder, reauthorize: true);
        }
        await model.keepFolderGrants({'JPG', 'RAW', 'OUT'});
        await model.openTask(model.currentTaskId);
      } else if (action == 'restore') {
        await _confirmRestore();
      }
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$exception')));
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> _confirmRestore() async {
    if (!model.canRestore || picking) return;
    setState(() => picking = true);
    try {
      final preview = await model.prepareRestore();
      if (!mounted) return;
      final decisions = await showRestoreConfirmation(context, preview);
      if (decisions != null && mounted) await model.restoreSources(decisions);
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$exception')));
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> _convertImages() async {
    if (model.busy || picking) return;
    setState(() => picking = true);
    try {
      final settings = await showConversionDialog(
        context,
        selectedCount: model.plan?.selected.length ?? 0,
        inputRoot: model.rawRoot,
        outputRoot: model.conversion?.directory != null
            ? p.dirname(p.dirname(model.conversion!.directory))
            : model.result?.directory ?? model.outputRoot,
      );
      if (settings != null && mounted) {
        await model.convertImages(
          settings.request,
          selectedOnly: settings.selectedOnly,
        );
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> _confirmExport() async {
    final plan = model.plan!;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(model.result == null ? '归档' : '继续归档'),
        content: SizedBox(
          width: 430,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${plan.selected.length} RAW + ${plan.count(MatchStatus.matched)} JPG',
              ),
              if (plan.count(MatchStatus.missing) +
                      plan.count(MatchStatus.conflict) >
                  0) ...[
                const SizedBox(height: 10),
                Text(
                  '跳过：未找到 ${plan.count(MatchStatus.missing)} · 待确认 ${plan.count(MatchStatus.conflict)}',
                  style: const TextStyle(fontSize: 12, color: Palette.muted),
                ),
              ],
              const SizedBox(height: 16),
              const Text(
                '保存位置',
                style: TextStyle(fontSize: 12, color: Palette.muted),
              ),
              const SizedBox(height: 4),
              SelectableText(model.result?.directory ?? model.outputRoot!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(plan.selected.isEmpty ? '生成清单' : '归档'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) await model.export();
  }

  Future<void> _confirmCleanup() async {
    final preview = model.cleanupPreview;
    var acknowledged = false;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('清理源文件'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${preview.rawCount} RAW + ${preview.jpgCount} JPG',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  '预计减少 ${formatBytes(preview.totalBytes)}',
                  style: const TextStyle(fontSize: 13, color: Palette.muted),
                ),
                const SizedBox(height: 12),
                const Text(
                  '归档位置',
                  style: TextStyle(fontSize: 12, color: Palette.muted),
                ),
                SelectableText(
                  model.result!.directory,
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 180,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Palette.line),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: ListView.builder(
                      itemCount: preview.targets.length,
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        child: Text(
                          preview.targets[i].source.path,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (preview.blockedGroups > 0)
                  Text(
                    '跳过 ${preview.blockedGroups} 组未完整归档的照片',
                    style: const TextStyle(color: Palette.amber, fontSize: 12),
                  ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: acknowledged,
                  onChanged: (value) => update(() => acknowledged = value!),
                  title: const Text(
                    '已核对归档。永久删除上述源文件，不进入回收站。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.7,
                      color: Palette.red,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留源文件'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Palette.red),
              onPressed: acknowledged
                  ? () => Navigator.pop(context, true)
                  : null,
              child: Text('删除 ${preview.targets.length} 个源文件'),
            ),
          ],
        ),
      ),
    );
    if (yes == true && mounted) await model.cleanSources();
  }

  Future<void> _openResult() async {
    await _openDirectory(model.result!.directory);
  }

  Future<void> _openDirectory(String path) async {
    try {
      final result = await Process.run(
        Platform.isMacOS ? '/usr/bin/open' : 'explorer.exe',
        [path],
      );
      if (result.exitCode != 0 &&
          !(Platform.isWindows && result.exitCode == 1)) {
        throw Exception(result.stderr);
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: path));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('结果路径已复制，可在文件管理器中打开。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.escape): _CancelIntent(),
    },
    child: Actions(
      actions: {
        _CancelIntent: CallbackAction<_CancelIntent>(
          onInvoke: (_) {
            if (model.busy) {
              model.cancel();
            }
            return null;
          },
        ),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: LayoutBuilder(
            builder: (context, bounds) {
              final compact = bounds.maxWidth < 1150;
              return Row(
                children: [
                  SizedBox(width: compact ? 216 : 232, child: _sidebar()),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Column(
                      children: [
                        _header(),
                        if (model.error != null) _errorBanner(),
                        if (model.conversion != null)
                          _conversionBanner()
                        else if (model.result != null)
                          _resultBanner(),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: ResultsPane(
                                  plan: model.plan,
                                  busy: model.phase == TaskPhase.scanning,
                                  scanMessage: model.scanMessage,
                                  selectedIndex: selectedIndex,
                                  filter: filter,
                                  query: query,
                                  onFilter: (v) => model.updateView(status: v),
                                  onQuery: (v) => model.updateView(search: v),
                                  archivedJpgs: archivedJpgs,
                                  onSelect: (v) =>
                                      model.updateView(selected: v),
                                ),
                              ),
                              if (!compact) ...[
                                const VerticalDivider(width: 1),
                                SizedBox(
                                  width: 300,
                                  child: PreviewPane(
                                    plan: model.plan,
                                    index: selectedIndex,
                                    busy: !model.canChoose(selectedIndex),
                                    archivedPath: archivedPreview,
                                    onChoose: (value) =>
                                        model.choose(selectedIndex!, value),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (compact &&
                            selectedIndex != null &&
                            model.plan != null)
                          _compactInspector(),
                        _footer(),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _sidebar() => ColoredBox(
    color: Palette.sidebar,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.filter_center_focus,
                size: 25,
                color: Palette.ink,
              ),
              SizedBox(width: 9),
              const Text(
                '拾片',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: '任务',
                enabled: !model.busy && !picking,
                icon: const Icon(Icons.history, size: 20, color: Palette.muted),
                onSelected: _taskAction,
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'history', child: Text('任务')),
                  const PopupMenuItem(value: 'new', child: Text('新任务')),
                  const PopupMenuItem(value: 'import', child: Text('打开归档')),
                  if (model.jpgRoot != null || model.rawRoot != null)
                    const PopupMenuItem(
                      value: 'authorize',
                      child: Text('授权目录'),
                    ),
                  if (model.canRestore)
                    const PopupMenuItem(value: 'restore', child: Text('恢复原位置')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 30),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _folderCard(
                    '已选 JPG',
                    model.jpgRoot,
                    Icons.photo_outlined,
                    () => _chooseFolder('JPG'),
                  ),
                  const SizedBox(height: 10),
                  _folderCard(
                    '全部 RAW',
                    model.rawRoot,
                    Icons.raw_on_outlined,
                    () => _chooseFolder('RAW'),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: model.canScan && !picking
                          ? () {
                              model.updateView(status: '全部', search: '');
                              model.scan();
                            }
                          : null,
                      icon: const Icon(Icons.sync, size: 16),
                      label: Text(
                        model.phase == TaskPhase.scanning
                            ? '匹配中…'
                            : model.plan == null
                            ? '匹配'
                            : model.result != null
                            ? '更新匹配'
                            : '重新匹配',
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  _folderCard(
                    '保存位置',
                    model.outputRoot,
                    Icons.folder_outlined,
                    () => _chooseFolder('OUT'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: model.busy || picking ? null : _convertImages,
              icon: const Icon(Icons.image_outlined, size: 17),
              label: const Text('RAW 转图片'),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _folderCard(
    String title,
    String? path,
    IconData icon,
    VoidCallback tap,
  ) => Tooltip(
    message: path ?? '选择文件夹',
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: model.locked || picking ? null : tap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: Palette.line),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 12, color: Palette.muted),
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  Icon(
                    icon,
                    size: 17,
                    color: path == null ? Palette.muted : Palette.green,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      path == null ? '选择文件夹' : p.basename(path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.chevron_right,
                    size: 15,
                    color: Palette.muted,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _header() {
    final plan = model.plan;
    final cleaned =
        model.cleanup != null && model.cleanupPreview.targets.isEmpty;
    final active = cleaned
        ? 3
        : model.result != null
        ? 2
        : plan != null
        ? 1
        : 0;
    return Container(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Palette.line)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: Icon(Icons.chevron_right, size: 14, color: Palette.line),
              ),
            Icon(
              i < active ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 14,
              color: i <= active ? Palette.green : Palette.muted,
            ),
            const SizedBox(width: 7),
            Text(
              ['匹配', '归档', '清理'][i],
              style: TextStyle(
                fontSize: 13,
                fontWeight: i == active ? FontWeight.w600 : FontWeight.w400,
                color: i <= active ? Palette.ink : Palette.muted,
              ),
            ),
          ],
          const Spacer(),
          if (plan != null)
            Text(
              '${plan.items.length} JPG / ${plan.rawCount} RAW',
              style: const TextStyle(fontSize: 12, color: Palette.muted),
            ),
        ],
      ),
    );
  }

  Widget _errorBanner() => Container(
    width: double.infinity,
    color: const Color(0xFFFFF0EC),
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
    child: SelectableText(
      model.error!,
      style: const TextStyle(color: Palette.red, fontSize: 13),
    ),
  );

  Widget _resultBanner() {
    final result = model.result!;
    final cleanup = model.cleanup;
    final restoration = model.restoration;
    final good = restoration != null
        ? restoration.failures.isEmpty &&
              restoration.skipped.isEmpty &&
              !restoration.cancelled &&
              restoration.error == null
        : cleanup == null
        ? result.complete
        : cleanup.failures.isEmpty &&
              cleanup.error == null &&
              !cleanup.cancelled;
    final title = model.restoration != null
        ? '已恢复 ${model.restoration!.restored.length} 个文件'
        : cleanup == null
        ? '${result.cancelled ? '已取消' : '已归档'} · ${result.copied.length} RAW / ${result.copiedJpg.length} JPG'
        : '已清理 ${cleanup.deleted.length} 个源文件 · ${formatBytes(cleanup.reclaimedBytes)}';
    return Container(
      width: double.infinity,
      color: good ? const Color(0xFFE8F3EE) : const Color(0xFFFFF3DF),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          Icon(
            good ? Icons.check_circle_outline : Icons.info_outline,
            size: 20,
            color: good ? Palette.green : Palette.amber,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (restoration != null && restoration.skipped.isNotEmpty)
                  Text(
                    '跳过 ${restoration.skipped.length} 项',
                    style: const TextStyle(fontSize: 12, color: Palette.amber),
                  ),
                if (restoration != null && restoration.failures.isNotEmpty)
                  Text(
                    '恢复失败 ${restoration.failures.length} 项',
                    style: const TextStyle(fontSize: 12, color: Palette.red),
                  ),
                if (restoration?.cancelled == true)
                  const Text(
                    '恢复已取消',
                    style: TextStyle(fontSize: 12, color: Palette.amber),
                  ),
                if (restoration?.error != null)
                  Text(
                    restoration!.error!,
                    style: const TextStyle(fontSize: 12, color: Palette.red),
                  ),
                if (result.failures.isNotEmpty)
                  Text(
                    '归档失败 ${result.failures.length} 项',
                    style: const TextStyle(fontSize: 12, color: Palette.amber),
                  ),
                if (cleanup != null && cleanup.failures.isNotEmpty)
                  Text(
                    '清理失败 ${cleanup.failures.length} 项',
                    style: const TextStyle(fontSize: 12, color: Palette.red),
                  ),
                if (cleanup?.cancelled == true)
                  const Text(
                    '清理已取消',
                    style: TextStyle(fontSize: 12, color: Palette.amber),
                  ),
                if (result.reportError != null || cleanup?.error != null)
                  Text(
                    cleanup?.error ?? result.reportError!,
                    style: const TextStyle(fontSize: 12, color: Palette.red),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Tooltip(
            message: result.directory,
            child: TextButton(
              onPressed: _openResult,
              child: const Text('查看归档'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactInspector() => Container(
    color: Colors.white,
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            model.plan!.items[selectedIndex!].jpg.name,
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton.icon(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => Dialog(
              child: SizedBox(
                width: 450,
                height: 600,
                child: PreviewPane(
                  plan: model.plan,
                  index: selectedIndex,
                  busy: !model.canChoose(selectedIndex),
                  archivedPath: archivedPreview,
                  onChoose: (value) {
                    model.choose(selectedIndex!, value);
                    Navigator.pop(context);
                  },
                ),
              ),
            ),
          ),
          icon: const Icon(Icons.open_in_full, size: 14),
          label: const Text('预览'),
        ),
      ],
    ),
  );

  Widget _conversionBanner() {
    final conversion = model.conversion!;
    final failures = conversion.failures;
    return Container(
      color: failures.isEmpty
          ? const Color(0xFFE8F3EE)
          : const Color(0xFFFFF3DF),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${conversion.cancelled ? '已取消' : '转换完成'} · '
              '${conversion.converted.length} 张${conversion.reused.isEmpty ? '' : ' · 复用 ${conversion.reused.length} 张'}',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if (failures.isNotEmpty)
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('未转换 ${failures.length} 张'),
                  content: SizedBox(
                    width: 520,
                    height: 260,
                    child: ListView(
                      children: [
                        for (final entry in failures.entries)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: SelectableText(
                              '${entry.key}\n${entry.value}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
              child: Text('失败 ${failures.length} 张'),
            ),
          TextButton(
            onPressed: () => _openDirectory(conversion.directory),
            child: const Text('查看图片'),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    final progress = model.progress;
    final working =
        model.phase == TaskPhase.copying ||
        model.phase == TaskPhase.cleaning ||
        model.phase == TaskPhase.restoring ||
        model.phase == TaskPhase.converting;
    final cleaning = model.phase == TaskPhase.cleaning;
    final preview = model.cleanupPreview;
    final String title;
    if (working) {
      title = progress == null
          ? (model.phase == TaskPhase.converting
                ? '准备转换…'
                : cleaning
                ? '准备复核源文件…'
                : '准备归档…')
          : '${progress.verifying
                ? '校验'
                : cleaning
                ? '清理'
                : model.phase == TaskPhase.restoring
                ? '恢复'
                : model.phase == TaskPhase.converting
                ? '转换'
                : '归档'} ${progress.completed} / ${progress.total}';
    } else if (model.result != null) {
      title = preview.targets.isNotEmpty
          ? '${preview.targets.length} 个源文件 · ${formatBytes(preview.totalBytes)}'
          : model.cleanup != null
          ? '已完成'
          : '已归档';
    } else {
      title = model.plan == null
          ? '未导入'
          : '${model.plan!.selected.length} RAW + ${model.plan!.count(MatchStatus.matched)} JPG';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Palette.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (working) ...[
            LinearProgressIndicator(
              value: progress?.fraction,
              minHeight: 3,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (working && progress != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        progress.file,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Palette.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (model.busy)
                OutlinedButton(
                  onPressed: model.cancellationRequested ? null : model.cancel,
                  child: Text(model.cancellationRequested ? '取消中…' : '取消'),
                )
              else ...[
                if (model.result != null)
                  TextButton(
                    onPressed: picking ? null : () => _taskAction('new'),
                    child: const Text('新任务'),
                  ),
                if (model.canExport || model.result == null)
                  FilledButton.icon(
                    onPressed: model.canExport && !picking
                        ? _confirmExport
                        : null,
                    icon: const Icon(Icons.inventory_2_outlined, size: 17),
                    label: Text(
                      model.result != null
                          ? '继续归档'
                          : model.plan != null && model.plan!.selected.isEmpty
                          ? '生成清单'
                          : '归档',
                    ),
                  ),
                if (model.canRestore)
                  TextButton(
                    onPressed: picking ? null : _confirmRestore,
                    child: const Text('恢复原位置'),
                  ),
                if (model.canClean)
                  FilledButton.icon(
                    onPressed: picking ? null : _confirmCleanup,
                    icon: const Icon(
                      Icons.cleaning_services_outlined,
                      size: 17,
                    ),
                    label: const Text('清理源文件'),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _CancelIntent extends Intent {
  const _CancelIntent();
}
