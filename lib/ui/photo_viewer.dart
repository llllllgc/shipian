import 'dart:io';
import 'palette.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/models.dart';
import '../core/photo_preview.dart';

class PhotoPreview extends StatefulWidget {
  const PhotoPreview({
    super.key,
    required this.entry,
    required this.service,
    this.thumbnail = false,
    this.fit = BoxFit.contain,
  });
  final PreviewEntry entry;
  final PhotoPreviewService service;
  final bool thumbnail;
  final BoxFit fit;
  @override
  State<PhotoPreview> createState() => _PhotoPreviewState();
}

class _PhotoPreviewState extends State<PhotoPreview> {
  late CancellationToken token;
  late Future<File> image;
  void load() {
    token = CancellationToken();
    image = widget.service.load(
      widget.entry,
      token,
      thumbnail: widget.thumbnail,
    );
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(PhotoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.path != widget.entry.path ||
        oldWidget.service != widget.service) {
      token.cancelled = true;
      load();
    }
  }

  @override
  void dispose() {
    token.cancelled = true;
    super.dispose();
  }

  Widget get loading => !widget.entry.isRaw
      ? const Center(child: Icon(Icons.image_outlined, color: Colors.white38))
      : const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white60,
            ),
          ),
        );
  Widget failed(String message) => Center(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: widget.thumbnail
          ? const Icon(
              Icons.broken_image_outlined,
              color: Colors.white38,
              size: 20,
            )
          : Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
    ),
  );

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Palette.canvas,
    child: FutureBuilder<File>(
      key: ValueKey(widget.entry.path),
      future: image,
      builder: (context, state) {
        if (state.hasError) {
          return Tooltip(message: '${state.error}', child: failed('无法预览此图片'));
        }
        if (!state.hasData) return loading;
        return Image.file(
          state.data!,
          key: ValueKey(state.data!.path),
          fit: widget.fit,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: widget.thumbnail ? 160 : 2560,
          frameBuilder: (_, child, frame, sync) =>
              sync || frame != null ? child : loading,
          errorBuilder: (_, error, trace) => failed('无法预览此图片'),
        );
      },
    ),
  );
}

Future<void> showPhotoViewer(
  BuildContext context, {
  required PhotoPreviewService service,
  List<PreviewEntry> entries = const [],
  int initialIndex = 0,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => PhotoViewer(
    service: service,
    entries: entries,
    initialIndex: initialIndex,
  ),
);

class PhotoViewer extends StatefulWidget {
  const PhotoViewer({
    super.key,
    required this.service,
    this.entries = const [],
    this.initialIndex = 0,
  });
  final PhotoPreviewService service;
  final List<PreviewEntry> entries;
  final int initialIndex;
  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late List<PreviewEntry> entries = widget.entries;
  late int index = entries.isEmpty
      ? 0
      : widget.initialIndex.clamp(0, entries.length - 1);
  final transform = TransformationController();
  final strip = ScrollController();
  final focus = FocusNode();
  CancellationToken? scan;
  bool picking = false;
  int generation = 0;
  String? error;
  @override
  void dispose() {
    scan?.cancelled = true;
    transform.dispose();
    strip.dispose();
    focus.dispose();
    super.dispose();
  }

  void select(int next) {
    if (entries.isEmpty || picking || next < 0 || next >= entries.length) {
      return;
    }
    setState(() {
      index = next;
      transform.value = Matrix4.identity();
    });
    focus.requestFocus();
    if (strip.hasClients) {
      final position =
          (index * 80.0 - strip.position.viewportDimension / 2 + 40).clamp(
            0.0,
            strip.position.maxScrollExtent,
          );
      strip.animateTo(
        position,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  void zoom(double factor) {
    final value = (transform.value.getMaxScaleOnAxis() * factor).clamp(
      1.0,
      8.0,
    );
    setState(
      () =>
          transform.value = Matrix4.identity()
            ..scaleByDouble(value, value, value, 1),
    );
    focus.requestFocus();
  }

  Future<void> open(String kind) async {
    if (picking) return;
    setState(() {
      picking = true;
      error = null;
    });
    try {
      if (kind == 'clear') {
        await widget.service.clearCache();
        if (mounted) setState(() => generation++);
        return;
      }
      List<PreviewEntry>? next;
      if (kind == 'folder') {
        final root = await getDirectoryPath(confirmButtonText: '打开图片文件夹');
        if (root != null) {
          scan = CancellationToken();
          next = await scanPreviewFolder(root, scan!);
        }
      } else {
        final files = await openFiles(
          acceptedTypeGroups: [
            XTypeGroup(
              label: '图片和 RAW',
              extensions: previewExtensions.map((s) => s.substring(1)).toList(),
            ),
          ],
        );
        if (files.isNotEmpty) {
          next = [for (final file in files) PreviewEntry(file.path)];
        }
      }
      if (mounted && next != null) {
        setState(() {
          entries = next!;
          index = 0;
          transform.value = Matrix4.identity();
          if (entries.isEmpty) error = '没有可预览的图片';
        });
        if (strip.hasClients) strip.jumpTo(0);
      }
    } on TaskCancelled {
      // The window was closed during a folder scan.
    } catch (exception) {
      if (mounted) {
        setState(
          () => error = exception is FormatException
              ? exception.message
              : '$exception',
        );
      }
    } finally {
      if (mounted) {
        setState(() => picking = false);
        focus.requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = entries.isEmpty ? null : entries[index];
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft): _MovePhoto(-1),
        SingleActivator(LogicalKeyboardKey.arrowRight): _MovePhoto(1),
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          _MovePhoto: CallbackAction<_MovePhoto>(
            onInvoke: (intent) {
              select(index + intent.delta);
              return null;
            },
          ),
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              Navigator.pop(context);
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: focus,
          autofocus: true,
          child: Dialog.fullscreen(
            backgroundColor: Palette.canvas,
            child: Theme(
              data: Theme.of(context).copyWith(
                iconTheme: const IconThemeData(color: Colors.white70),
                iconButtonTheme: IconButtonThemeData(
                  style: IconButton.styleFrom(
                    foregroundColor: Colors.white70,
                    disabledForegroundColor: Colors.white24,
                  ),
                ),
                outlinedButtonTheme: OutlinedButtonThemeData(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white38),
                  ),
                ),
                textButtonTheme: TextButtonThemeData(
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        PopupMenuButton<String>(
                          tooltip: '打开图片',
                          enabled: !picking,
                          onSelected: open,
                          icon: const Icon(Icons.folder_open_outlined),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'files', child: Text('打开图片')),
                            PopupMenuItem(
                              value: 'folder',
                              child: Text('打开文件夹'),
                            ),
                            PopupMenuItem(
                              value: 'clear',
                              child: Text('清理预览缓存'),
                            ),
                          ],
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            entry?.title ?? '图片预览',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (entry?.isRaw == true)
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              'RAW',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: '缩小',
                          onPressed: entry == null ? null : () => zoom(1 / 1.5),
                          icon: const Icon(Icons.remove),
                        ),
                        TextButton(
                          onPressed: entry == null
                              ? null
                              : () {
                                  setState(
                                    () => transform.value = Matrix4.identity(),
                                  );
                                },
                          child: const Text('适应'),
                        ),
                        IconButton(
                          tooltip: '放大',
                          onPressed: entry == null ? null : () => zoom(1.5),
                          icon: const Icon(Icons.add),
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          tooltip: '关闭预览',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        error!,
                        style: const TextStyle(
                          color: Color(0xFFFFC2AE),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  Expanded(
                    child: picking
                        ? const Center(child: CircularProgressIndicator())
                        : entry == null
                        ? Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () => open('files'),
                                  icon: const Icon(Icons.image_outlined),
                                  label: const Text('打开图片'),
                                ),
                                const SizedBox(width: 16),
                                TextButton(
                                  onPressed: () => open('folder'),
                                  child: const Text('打开文件夹'),
                                ),
                              ],
                            ),
                          )
                        : Row(
                            children: [
                              IconButton(
                                tooltip: '上一张',
                                onPressed: index > 0
                                    ? () => select(index - 1)
                                    : null,
                                icon: const Icon(Icons.chevron_left),
                              ),
                              Expanded(
                                child: ClipRect(
                                  child: GestureDetector(
                                    onDoubleTap: () => zoom(
                                      transform.value.getMaxScaleOnAxis() > 1
                                          ? .01
                                          : 2,
                                    ),
                                    child: InteractiveViewer(
                                      transformationController: transform,
                                      minScale: 1,
                                      maxScale: 8,
                                      trackpadScrollCausesScale: true,
                                      child: PhotoPreview(
                                        key: ValueKey(
                                          'main:$generation:${entry.path}',
                                        ),
                                        entry: entry,
                                        service: widget.service,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '下一张',
                                onPressed: index + 1 < entries.length
                                    ? () => select(index + 1)
                                    : null,
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ],
                          ),
                  ),
                  if (entries.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        '${index + 1} / ${entries.length}',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 80,
                      child: ListView.builder(
                        controller: strip,
                        scrollDirection: Axis.horizontal,
                        itemExtent: 80,
                        itemCount: entries.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                          child: Tooltip(
                            message: entries[i].title,
                            child: InkWell(
                              onTap: () => select(i),
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    width: 2,
                                    color: i == index
                                        ? Colors.white70
                                        : Colors.transparent,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: PhotoPreview(
                                  key: ValueKey(
                                    'thumb:$generation:${entries[i].path}',
                                  ),
                                  entry: entries[i],
                                  service: widget.service,
                                  thumbnail: true,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MovePhoto extends Intent {
  const _MovePhoto(this.delta);
  final int delta;
}
