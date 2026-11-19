import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../app_controller.dart';
import '../culling_controller.dart';
import '../core/culling.dart';
import '../core/converter.dart';
import '../core/photo_preview.dart';
import 'conversion_dialog.dart';
import 'palette.dart';
import 'photo_viewer.dart';
import 'workbench.dart';
import 'workspace.dart';
import 'photo_stage.dart';
import '../core/models.dart';

class CullingHome extends StatefulWidget {
  const CullingHome({super.key, this.controller, this.legacyController});
  final CullingController? controller;
  final PickerController? legacyController;
  @override
  State<CullingHome> createState() => _CullingHomeState();
}

class _CullingHomeState extends State<CullingHome> {
  late final model = widget.controller ?? CullingController();
  final previews = PhotoPreviewService();
  late final archive = widget.legacyController ?? PickerController();
  bool archiveMode = false, archiveLoaded = false;
  bool rawView = false, picking = false;
  String? get currentPath {
    final item = model.current, session = model.session;
    if (item == null || session == null) return null;
    final raw = session.rawFor(item);
    return session.pathFor(rawView && raw != null ? raw : item.jpg);
  }

  @override
  void initState() {
    super.initState();
    model.addListener(changed);
    model.closePreviews = previews.cancelPending;
  }

  void changed() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    model.removeListener(changed);
    model.closePreviews = null;
    previews.close();
    if (widget.legacyController == null) archive.dispose();
    if (widget.controller == null) model.dispose();
    super.dispose();
  }

  Future<void> chooseSource() async {
    if (picking || model.busy) return;
    setState(() => picking = true);
    try {
      final folder = await getDirectoryPath(confirmButtonText: '选择源文件夹');
      if (folder != null) await model.openSource(folder);
    } catch (error) {
      if (mounted) message('$error');
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  void message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> showLarge() async {
    if (model.busy || picking || currentPath == null) return;
    setState(() => picking = true);
    try {
      final state = model.session!;
      final entries = matchedPreviews(state.plan, {
        for (final file in [
          ...state.raws,
          ...state.plan.items.map((i) => i.jpg),
        ])
          file.path: state.pathFor(file),
      });
      await showPhotoViewer(
        context,
        service: previews,
        entries: entries,
        initialIndex: entries.indexWhere((entry) => entry.path == currentPath),
      );
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> tool(String action) async {
    if (picking || model.busy) return;
    if (action == 'refresh') {
      await model.rescan();
      return;
    }
    if (action == 'issues') {
      await issues();
      return;
    }
    setState(() => picking = true);
    try {
      if (action == 'preview') {
        await showPhotoViewer(context, service: previews);
      } else if (action == 'convert') {
        final session = model.session;
        final settings = await showConversionDialog(
          context,
          selectedCount: 0,
          inputRoot: session?.root,
          outputRoot: session?.root,
        );
        if (settings == null || !mounted) return;
        final legacy = widget.legacyController ?? PickerController();
        try {
          final result = legacy.convertImages(
            ConversionRequest(
              inputRoot: settings.request.inputRoot,
              outputRoot: settings.request.outputRoot,
              format: settings.request.format,
              quality: settings.request.quality,
            ),
          );
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (context) => ListenableBuilder(
              listenable: legacy,
              builder: (context, _) => PopScope(
                canPop: !legacy.busy,
                child: AlertDialog(
                  title: Text(legacy.busy ? '转换中' : '转换完成'),
                  content: SizedBox(
                    width: 360,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (legacy.busy)
                          LinearProgressIndicator(
                            value: legacy.progress?.fraction,
                          ),
                        const SizedBox(height: 12),
                        Text(
                          legacy.error ??
                              (legacy.busy
                                  ? '${legacy.progress?.completed ?? 0} / ${legacy.progress?.total ?? 0}'
                                  : '${legacy.conversion?.completed ?? 0} 张 · 失败 ${legacy.conversion?.failures.length ?? 0} 张'),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: legacy.busy
                          ? legacy.cancel
                          : () => Navigator.pop(context),
                      child: Text(legacy.busy ? '取消' : '关闭'),
                    ),
                  ],
                ),
              ),
            ),
          );
          await result;
        } finally {
          if (widget.legacyController == null) legacy.dispose();
        }
      } else if (action == 'archive') {
        await model.saveNow();
        await previews.cancelPending();
        if (!archiveLoaded && archive.plan == null) await archive.initialize();
        archiveLoaded = true;
        if (mounted) setState(() => archiveMode = true);
      }
    } catch (error) {
      if (mounted) message('$error');
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> issues() async {
    final state = model.session;
    if (state == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('匹配异常'),
        content: SizedBox(
          width: 520,
          height: 300,
          child: ListView(
            children: [
              for (final item in state.plan.items)
                if (state.rawFor(item) == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '${item.jpg.relativePath}\n${item.status.name == 'conflict' && !state.skippedRaw.contains(item.jpg.path) ? '请在右栏选择 RAW，或选择仅整理 JPG' : '仅整理 JPG'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              if (state.unmatchedRaw.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: Text(
                    '以下 RAW 无对应 JPG，留在原处',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              for (final raw in state.unmatchedRaw)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    raw.relativePath,
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
    );
  }

  Future<void> sort() async {
    if (!model.canSort) return;
    final state = model.session!;
    if (!state.started &&
        (state.missing > 0 || state.unmatchedRaw.isNotEmpty)) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('筛选'),
          content: Text(
            '${state.missing} 张 JPG 无对应 RAW，仍整理到 JPG。\n${state.unmatchedRaw.length} 个未配对 RAW 留在原处。',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续筛选'),
            ),
          ],
        ),
      );
      if (yes != true) return;
    }
    await model.organize();
  }

  Future<void> openFolder(String name) async {
    final root = model.session?.root;
    if (root == null) return;
    final path = p.join(root, name);
    try {
      await Process.run(Platform.isMacOS ? '/usr/bin/open' : 'explorer.exe', [
        path,
      ]);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: path));
      if (mounted) message('文件夹路径已复制');
    }
  }

  void decide(PickDecision decision) {
    if (!picking && model.visible.contains(model.session?.index)) {
      model.decide(decision);
    }
  }

  @override
  Widget build(BuildContext context) => archiveMode
      ? Workbench(
          controller: archive,
          onCulling: () => setState(() => archiveMode = false),
        )
      : Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.digit1): _CullAction('keep'),
            SingleActivator(LogicalKeyboardKey.keyP): _CullAction('keep'),
            SingleActivator(LogicalKeyboardKey.digit2): _CullAction('reject'),
            SingleActivator(LogicalKeyboardKey.keyX): _CullAction('reject'),
            SingleActivator(LogicalKeyboardKey.arrowLeft): _CullAction(
              'previous',
            ),
            SingleActivator(LogicalKeyboardKey.arrowRight): _CullAction('next'),
            SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _CullAction(
              'undo',
            ),
            SingleActivator(LogicalKeyboardKey.keyZ, control: true):
                _CullAction('undo'),
          },
          child: Actions(
            actions: {
              _CullAction: CallbackAction<_CullAction>(
                onInvoke: (intent) {
                  if (picking) return null;
                  switch (intent.action) {
                    case 'keep':
                      decide(PickDecision.keep);
                    case 'reject':
                      decide(PickDecision.reject);
                    case 'previous':
                      model.next(-1);
                    case 'next':
                      model.next(1);
                    case 'undo':
                      model.undo();
                  }
                  return null;
                },
              ),
            },
            child: Focus(autofocus: true, child: _workspace()),
          ),
        );

  Widget _workspace() {
    final state = model.session, item = model.current;
    final enabled = !model.busy && !picking;
    final visible = model.visible;
    final position = state == null ? -1 : visible.indexOf(state.index);
    final keep = state?.count(PickDecision.keep) ?? 0;
    final reject = state?.count(PickDecision.reject) ?? 0;
    final total = state?.plan.items.length ?? 0;
    final raw = item == null ? null : state!.rawFor(item);
    return WorkspaceFrame(
      mode: WorkspaceMode.culling,
      onSwitch: enabled ? () => tool('archive') : null,
      title: state == null ? '选片整理' : p.basename(state.root),
      toolbar: [
        if (state != null)
          Text(
            '已处理 ${state.processed} / $total',
            style: const TextStyle(fontSize: 12, color: Palette.muted),
          ),
      ],
      sidebar: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SidebarHeading('来源'),
          SidebarRow(
            label: '源文件夹',
            icon: Icons.folder_outlined,
            detail: state == null ? '未选择' : p.basename(state.root),
            tooltip: state?.root ?? '打开源文件夹',
            onTap: enabled ? chooseSource : null,
          ),
          if (state != null) ...[
            const SizedBox(height: 16),
            const SidebarHeading('照片'),
            for (final (label, icon, count) in [
              ('全部', Icons.grid_view_outlined, total),
              ('未决定', Icons.radio_button_unchecked, total - keep - reject),
              ('保留', Icons.check, keep),
              ('不要', Icons.close, reject),
            ])
              SidebarRow(
                label: label,
                icon: icon,
                count: count,
                selected: model.filter == label,
                onTap: enabled ? () => model.setFilter(label) : null,
              ),
          ],
        ],
      ),
      tools: Column(
        children: [
          SidebarRow(
            label: '图片预览',
            icon: Icons.visibility_outlined,
            onTap: enabled ? () => tool('preview') : null,
          ),
          SidebarRow(
            label: 'RAW 转图片',
            icon: Icons.transform,
            onTap: enabled ? () => tool('convert') : null,
          ),
          if (state != null && !state.started)
            SidebarRow(
              label: '重新扫描',
              icon: Icons.refresh,
              onTap: enabled ? () => tool('refresh') : null,
            ),
        ],
      ),
      notice: model.error == null
          ? null
          : Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                model.error!,
                style: const TextStyle(color: Palette.red, fontSize: 12),
              ),
            ),
      content: state == null
          ? model.busy
                ? const Center(child: CircularProgressIndicator())
                : WorkspaceEmpty(
                    title: '打开照片文件夹',
                    hint: '选择存放 JPG 和 RAW 的文件夹，开始逐张选片。',
                    action: FilledButton.icon(
                      onPressed: enabled ? chooseSource : null,
                      icon: const Icon(Icons.folder_open_outlined, size: 16),
                      label: const Text('选择源文件夹'),
                    ),
                  )
          : Row(
              children: [
                Expanded(
                  child: position < 0
                      ? WorkspaceEmpty(
                          title: '没有${model.filter}的照片',
                          hint: '可以在侧栏查看全部照片。',
                          action: TextButton(
                            onPressed: () => model.setFilter('全部'),
                            child: const Text('显示全部'),
                          ),
                        )
                      : Column(
                          children: [
                            Expanded(
                              child: PhotoStage(
                                entry: PreviewEntry(currentPath!),
                                service: previews,
                                showingRaw: rawView && raw != null,
                                onFormat: raw == null
                                    ? null
                                    : (value) =>
                                          setState(() => rawView = value),
                                onExpand: enabled ? showLarge : null,
                              ),
                            ),
                            Filmstrip(
                              position: position,
                              count: visible.length,
                              service: previews,
                              entryAt: (i) {
                                final jpg = state.plan.items[visible[i]].jpg;
                                return PreviewEntry(
                                  state.pathFor(jpg),
                                  label: jpg.relativePath,
                                );
                              },
                              onSelect: enabled
                                  ? (i) => model.select(visible[i])
                                  : null,
                              markAt: (i) => switch (state.decisions[state
                                  .plan
                                  .items[visible[i]]
                                  .jpg
                                  .path]) {
                                PickDecision.keep => Icons.check,
                                PickDecision.reject => Icons.close,
                                null => null,
                              },
                            ),
                          ],
                        ),
                ),
                if (position >= 0) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: MediaQuery.sizeOf(context).width < 1150 ? 204 : 244,
                    child: _decisions(),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _decisions() {
    final state = model.session!,
        item = model.current!,
        decision = state.decisions[item.jpg.path];
    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '照片信息',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 20),
            Text(
              item.jpg.name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              formatBytes(item.jpg.size),
              style: const TextStyle(fontSize: 12, color: Palette.muted),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),
            Text(
              state.finished
                  ? '已整理'
                  : decision == null
                  ? '未决定'
                  : decision == PickDecision.keep
                  ? '已标记保留'
                  : '已标记不要',
              style: const TextStyle(fontSize: 12, color: Palette.muted),
            ),
            const SizedBox(height: 10),
            if (!state.started) ...[
              Tooltip(
                message: '保留（1 / P）',
                child: FilledButton.icon(
                  onPressed: model.canDecide && !picking
                      ? () => decide(PickDecision.keep)
                      : null,
                  icon: const Icon(Icons.check, size: 20),
                  label: const Text('保留'),
                ),
              ),
              const SizedBox(height: 10),
              Tooltip(
                message: '不要（2 / X）',
                child: OutlinedButton.icon(
                  onPressed: model.canDecide && !picking
                      ? () => decide(PickDecision.reject)
                      : null,
                  icon: const Icon(Icons.close, size: 20),
                  label: const Text('不要'),
                ),
              ),
              TextButton.icon(
                onPressed: model.canUndo && !picking ? model.undo : null,
                icon: const Icon(Icons.undo, size: 17),
                label: const Text('撤销'),
              ),
            ],
            const SizedBox(height: 18),
            Text(
              '对应 RAW',
              style: const TextStyle(fontSize: 12, color: Palette.muted),
            ),
            const SizedBox(height: 8),
            if (item.candidates.length > 1)
              DropdownButton<String>(
                isExpanded: true,
                value: state.skippedRaw.contains(item.jpg.path)
                    ? ''
                    : item.raw?.path,
                hint: const Text('选择 RAW', style: TextStyle(fontSize: 12)),
                items: [
                  for (final raw in item.candidates)
                    DropdownMenuItem(
                      value: raw.path,
                      child: Text(
                        raw.relativePath,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  const DropdownMenuItem(
                    value: '',
                    child: Text('仅整理 JPG', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: model.canDecide
                    ? (value) => model.chooseRaw(value == '' ? null : value)
                    : null,
              )
            else
              Text(
                item.raw?.relativePath ?? '未找到',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: item.raw == null ? Palette.amber : Palette.ink,
                ),
              ),
            if (state.conflicts + state.missing + state.unmatchedRaw.length > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: issues,
                  child: Text(
                    '匹配异常 ${state.conflicts + state.missing + state.unmatchedRaw.length}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            const Spacer(),
            if (model.busy) ...[
              LinearProgressIndicator(
                value: model.total == 0 ? null : model.completed / model.total,
              ),
              const SizedBox(height: 10),
              Text(
                model.sorting
                    ? '整理 ${model.completed} / ${model.total}'
                    : '读取中…',
                style: const TextStyle(fontSize: 12),
              ),
              TextButton(onPressed: model.cancel, child: const Text('取消')),
            ] else if (state.finished) ...[
              for (final folder in [
                pickedRawFolder,
                rejectedRawFolder,
                allJpgFolder,
              ])
                TextButton.icon(
                  onPressed: () => openFolder(folder),
                  icon: const Icon(Icons.folder_open_outlined, size: 17),
                  label: Text(folder),
                ),
            ] else
              FilledButton.icon(
                onPressed: model.canSort && !picking ? sort : null,
                icon: const Icon(Icons.folder_copy_outlined, size: 18),
                label: Text(state.started ? '继续筛选' : '筛选'),
              ),
          ],
        ),
      ),
    );
  }
}

class _CullAction extends Intent {
  const _CullAction(this.action);
  final String action;
}
