import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../app_controller.dart';
import '../core/models.dart';
import '../core/photo_preview.dart';
import 'conversion_dialog.dart';
import 'palette.dart';
import 'preview_pane.dart';
import 'photo_viewer.dart';
import 'results_pane.dart';
import 'task_dialogs.dart';
import 'workspace.dart';
import 'photo_stage.dart';

class Workbench extends StatefulWidget {
  const Workbench({super.key, this.controller, this.onCulling});
  final PickerController? controller;
  final VoidCallback? onCulling;
  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> {
  late final PickerController model = widget.controller ?? PickerController();
  late final search = TextEditingController(text: model.query);
  bool listMode = false, rawView = false;
  String? candidatePath, candidateJpg;

  bool picking = false;
  final previews = PhotoPreviewService();
  Map<String, String> get archivedRaws => {
    for (final receipt in model.result?.receipts ?? <ArchiveReceipt>[])
      if (receipt.kind == PhotoKind.raw)
        receipt.source.path: p.join(
          model.result!.directory,
          receipt.destinationRelativePath,
        ),
  };
  Map<String, String> get archivedJpgs => {
    for (final receipt in model.result?.receipts ?? <ArchiveReceipt>[])
      if (receipt.kind == PhotoKind.jpg)
        receipt.source.path: p.join(
          model.result!.directory,
          receipt.destinationRelativePath,
        ),
  };
  @override
  void initState() {
    super.initState();
    model.addListener(_changed);
    model.closePreviews = previews.cancelPending;
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
    if (search.text != model.query) search.text = model.query;
    setState(() {});
  }

  @override
  void dispose() {
    search.dispose();
    model.removeListener(_changed);
    model.closePreviews = null;
    previews.close();
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

  Future<void> _previewImages([String? path]) async {
    if (picking || model.busy) return;
    setState(() => picking = true);
    try {
      final entries = path == null || model.plan == null
          ? <PreviewEntry>[]
          : matchedPreviews(model.plan!, {...archivedJpgs, ...archivedRaws});
      final index = path == null
          ? 0
          : entries.indexWhere((entry) => entry.path == path);
      await showPhotoViewer(
        context,
        service: previews,
        entries: entries,
        initialIndex: index < 0 ? 0 : index,
      );
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
      child: Focus(autofocus: true, child: _workspace()),
    ),
  );

  Widget _workspace() {
    final enabled = !picking && !model.busy;
    final plan = model.plan;
    final term = model.query.trim().toLowerCase();
    final status = switch (model.filter) {
      '已匹配' => MatchStatus.matched,
      '待确认' => MatchStatus.conflict,
      '未找到' => MatchStatus.missing,
      _ => null,
    };
    final indices = <int>[
      if (plan != null)
        for (var i = 0; i < plan.items.length; i++)
          if ((status == null || plan.items[i].status == status) &&
              (term.isEmpty ||
                  plan.items[i].jpg.relativePath.toLowerCase().contains(term) ||
                  plan.items[i].candidates.any(
                    (f) => f.relativePath.toLowerCase().contains(term),
                  )))
            i,
    ];
    final selected = indices.contains(model.selectedIndex)
        ? model.selectedIndex
        : indices.firstOrNull;
    final item = selected == null ? null : plan!.items[selected];
    final jpgs = archivedJpgs, raws = archivedRaws;
    final candidate = item?.jpg.path == candidateJpg
        ? item?.candidates
              .where((f) => (raws[f.path] ?? f.path) == candidatePath)
              .firstOrNull
        : null;
    final raw = candidate ?? item?.raw;
    final showingRaw = rawView && raw != null;
    final file = showingRaw ? raw : item?.jpg;
    final path = file == null
        ? null
        : (showingRaw ? raws : jpgs)[file.path] ?? file.path;
    void select(int index) {
      candidatePath = candidateJpg = null;
      model.updateView(selected: index);
    }

    return WorkspaceFrame(
      mode: WorkspaceMode.archive,
      onSwitch: enabled ? widget.onCulling : null,
      title: model.jpgRoot == null ? '匹配归档' : p.basename(model.jpgRoot!),
      toolbar: [
        if (plan != null) ...[
          Text(
            '${plan.items.length} JPG / ${plan.rawCount} RAW',
            style: const TextStyle(fontSize: 12, color: Palette.muted),
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: listMode ? '查看照片' : '查看匹配列表',
            onPressed: () => setState(() => listMode = !listMode),
            icon: Icon(
              listMode ? Icons.photo_outlined : Icons.view_list_outlined,
            ),
          ),
        ],
        PopupMenuButton<String>(
          tooltip: '归档任务',
          enabled: enabled,
          icon: const Icon(Icons.history, size: 18),
          onSelected: _taskAction,
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'history', child: Text('历史任务')),
            const PopupMenuItem(value: 'new', child: Text('新任务')),
            const PopupMenuItem(value: 'import', child: Text('打开归档')),
            if (model.jpgRoot != null || model.rawRoot != null)
              const PopupMenuItem(value: 'authorize', child: Text('授权目录')),
            if (model.canRestore)
              const PopupMenuItem(value: 'restore', child: Text('恢复原位置')),
          ],
        ),
      ],
      sidebar: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SidebarHeading('归档目录'),
          for (final (kind, label, root) in [
            ('JPG', '已选 JPG', model.jpgRoot),
            ('RAW', '全部 RAW', model.rawRoot),
            ('OUT', '保存位置', model.outputRoot),
          ])
            SidebarRow(
              label: label,
              detail: root == null ? '选择文件夹' : p.basename(root),
              tooltip: root ?? label,
              icon: Icons.folder_outlined,
              onTap: model.locked || picking ? null : () => _chooseFolder(kind),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
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
                  : plan == null
                  ? '匹配'
                  : model.result != null
                  ? '更新匹配'
                  : '重新匹配',
            ),
          ),
          if (plan != null) ...[
            const SizedBox(height: 16),
            const SidebarHeading('匹配结果'),
            TextField(
              controller: search,
              onChanged: (v) => model.updateView(search: v),
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                hintText: '搜索文件名',
                prefixIcon: Icon(Icons.search, size: 16),
              ),
            ),
            const SizedBox(height: 6),
            for (final (label, icon, count) in [
              ('全部', Icons.grid_view_outlined, plan.items.length),
              (
                '已匹配',
                Icons.check_circle_outline,
                plan.count(MatchStatus.matched),
              ),
              ('待确认', Icons.help_outline, plan.count(MatchStatus.conflict)),
              (
                '未找到',
                Icons.remove_circle_outline,
                plan.count(MatchStatus.missing),
              ),
            ])
              SidebarRow(
                label: label,
                icon: icon,
                count: count,
                selected: model.filter == label,
                onTap: () => model.updateView(status: label),
              ),
          ],
        ],
      ),
      tools: Column(
        children: [
          SidebarRow(
            label: '图片预览',
            icon: Icons.visibility_outlined,
            onTap: enabled ? () => _previewImages() : null,
          ),
          SidebarRow(
            label: 'RAW 转图片',
            icon: Icons.transform,
            onTap: enabled ? _convertImages : null,
          ),
        ],
      ),
      notice: Column(
        children: [
          if (model.error != null) _errorBanner(),
          if (model.conversion != null)
            _conversionBanner()
          else if (model.result != null)
            _resultBanner(),
        ],
      ),
      content: model.phase == TaskPhase.scanning
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(model.scanMessage),
                ],
              ),
            )
          : plan == null
          ? const WorkspaceEmpty(
              title: '匹配 JPG 与 RAW',
              hint: '在侧栏选择已选 JPG 和全部 RAW 文件夹，然后开始匹配。',
            )
          : item == null
          ? const WorkspaceEmpty(title: '无结果', hint: '查看其他匹配状态，或调整搜索条件。')
          : Row(
              children: [
                Expanded(
                  child: listMode
                      ? ResultsPane(
                          plan: plan,
                          indices: indices,
                          selectedIndex: selected,
                          archivedJpgs: jpgs,
                          onSelect: select,
                          onOpen: (index) {
                            select(index);
                            setState(() => listMode = false);
                          },
                        )
                      : Column(
                          children: [
                            Expanded(
                              child: PhotoStage(
                                entry: PreviewEntry(
                                  path!,
                                  label: file!.relativePath,
                                ),
                                service: previews,
                                showingRaw: showingRaw,
                                onFormat: raw == null
                                    ? null
                                    : (value) =>
                                          setState(() => rawView = value),
                                onExpand: enabled
                                    ? () => _previewImages(path)
                                    : null,
                              ),
                            ),
                            Filmstrip(
                              position: indices.indexOf(selected!),
                              count: indices.length,
                              service: previews,
                              entryAt: (i) {
                                final jpg = plan.items[indices[i]].jpg;
                                return PreviewEntry(
                                  jpgs[jpg.path] ?? jpg.path,
                                  label: jpg.relativePath,
                                );
                              },
                              onSelect: (i) => select(indices[i]),
                            ),
                          ],
                        ),
                ),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: MediaQuery.sizeOf(context).width < 1150 ? 204 : 244,
                  child: PreviewPane(
                    plan: plan,
                    index: selected,
                    busy: !model.canChoose(selected),
                    archivedRaws: raws,
                    service: previews,
                    onExpand: (value) => setState(() {
                      candidatePath = value;
                      candidateJpg = item.jpg.path;
                      rawView = true;
                      listMode = false;
                    }),
                    onChoose: (value) {
                      candidatePath = candidateJpg = null;
                      model.choose(selected!, value);
                    },
                  ),
                ),
              ],
            ),
      footer: _footer(),
    );
  }

  Widget _errorBanner() => Container(
    width: double.infinity,
    color: Palette.surface,
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
      color: Palette.background,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          Icon(
            good ? Icons.check_circle_outline : Icons.info_outline,
            size: 20,
            color: good ? Palette.control : Palette.amber,
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

  Widget _conversionBanner() {
    final conversion = model.conversion!;
    final failures = conversion.failures;
    return Container(
      color: Palette.background,
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
