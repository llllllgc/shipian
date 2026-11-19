import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/photo_preview.dart';
import 'palette.dart';
import 'photo_viewer.dart';

/// The viewing surface is shared by both workflows. Changing files always fits
/// the new photo to the canvas, including when inspecting a different RAW.
class PhotoStage extends StatefulWidget {
  const PhotoStage({
    super.key,
    required this.entry,
    required this.service,
    required this.showingRaw,
    required this.onFormat,
    required this.onExpand,
  });
  final PreviewEntry entry;
  final PhotoPreviewService service;
  final bool showingRaw;
  final ValueChanged<bool>? onFormat;
  final VoidCallback? onExpand;
  @override
  State<PhotoStage> createState() => _PhotoStageState();
}

class _PhotoStageState extends State<PhotoStage> {
  final transform = TransformationController();
  @override
  void didUpdateWidget(PhotoStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entry.path != oldWidget.entry.path) {
      transform.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  void zoom(double scale, Size viewport) {
    final target = scale.clamp(1.0, 8.0);
    final center = viewport.center(Offset.zero);
    final point = transform.toScene(center);
    transform.value = target == 1
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(center.dx, center.dy, 0, 1)
            ..scaleByDouble(target, target, target, 1)
            ..translateByDouble(-point.dx, -point.dy, 0, 1));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final viewport = Size(bounds.maxWidth, bounds.maxHeight - 44);
      return Column(
        children: [
          Expanded(
            child: ClipRect(
              child: GestureDetector(
                onDoubleTap: () => zoom(
                  transform.value.getMaxScaleOnAxis() > 1 ? 1 : 2,
                  viewport,
                ),
                child: InteractiveViewer(
                  transformationController: transform,
                  minScale: 1,
                  maxScale: 8,
                  trackpadScrollCausesScale: true,
                  child: PhotoPreview(
                    entry: widget.entry,
                    service: widget.service,
                  ),
                ),
              ),
            ),
          ),
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: Palette.surface,
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: widget.entry.title,
                    child: Text(
                      widget.entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                if (widget.onFormat != null)
                  CupertinoSlidingSegmentedControl<bool>(
                    groupValue: widget.showingRaw,
                    onValueChanged: (value) {
                      if (value != null) widget.onFormat!(value);
                    },
                    children: const {
                      false: Text('JPG', style: TextStyle(fontSize: 11)),
                      true: Text('RAW', style: TextStyle(fontSize: 11)),
                    },
                  ),
                const SizedBox(width: 12),
                IconButton(
                  tooltip: '缩小',
                  onPressed: () =>
                      zoom(transform.value.getMaxScaleOnAxis() / 1.5, viewport),
                  icon: const Icon(Icons.remove),
                ),
                IconButton(
                  tooltip: '适应窗口',
                  onPressed: () => zoom(1, viewport),
                  icon: const Icon(Icons.fit_screen_outlined),
                ),
                IconButton(
                  tooltip: '放大',
                  onPressed: () =>
                      zoom(transform.value.getMaxScaleOnAxis() * 1.5, viewport),
                  icon: const Icon(Icons.add),
                ),
                IconButton(
                  tooltip: '大图预览',
                  onPressed: widget.onExpand,
                  icon: const Icon(Icons.open_in_full),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

class Filmstrip extends StatefulWidget {
  const Filmstrip({
    super.key,
    required this.count,
    required this.position,
    required this.entryAt,
    required this.onSelect,
    required this.service,
    this.markAt,
  });
  final int count, position;
  final PreviewEntry Function(int) entryAt;
  final ValueChanged<int>? onSelect;
  final IconData? Function(int)? markAt;
  final PhotoPreviewService service;
  @override
  State<Filmstrip> createState() => _FilmstripState();
}

class _FilmstripState extends State<Filmstrip> {
  final scroll = ScrollController();
  static const extent = 76.0;
  void reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || !scroll.hasClients || widget.position < 0) return;
    final start = extent * widget.position;
    final width = scroll.position.viewportDimension;
    if (start < scroll.offset || start + extent > scroll.offset + width) {
      scroll.jumpTo(
        (start - (width - extent) / 2).clamp(
          0.0,
          scroll.position.maxScrollExtent,
        ),
      );
    }
  });
  @override
  void initState() {
    super.initState();
    reveal();
  }

  @override
  void didUpdateWidget(Filmstrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position ||
        oldWidget.count != widget.count) {
      reveal();
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    height: 84,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    decoration: const BoxDecoration(
      color: Palette.background,
      border: Border(top: BorderSide(color: Palette.line)),
    ),
    child: Row(
      children: [
        IconButton(
          tooltip: '上一张',
          onPressed: widget.position > 0 && widget.onSelect != null
              ? () => widget.onSelect!(widget.position - 1)
              : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: ListView.builder(
            controller: scroll,
            scrollDirection: Axis.horizontal,
            itemExtent: extent,
            itemCount: widget.count,
            itemBuilder: (context, index) {
              final entry = widget.entryAt(index),
                  selected = index == widget.position,
                  mark = widget.markAt?.call(index);
              return Tooltip(
                message: entry.title,
                child: Semantics(
                  button: true,
                  selected: selected,
                  label: entry.title,
                  child: InkWell(
                    onTap: widget.onSelect == null
                        ? null
                        : () => widget.onSelect!(index),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: selected ? Palette.ink : Colors.transparent,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            PhotoPreview(
                              entry: entry,
                              service: widget.service,
                              thumbnail: true,
                              fit: BoxFit.cover,
                            ),
                            if (mark != null)
                              Positioned(
                                right: 3,
                                bottom: 3,
                                child: DecoratedBox(
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.black87,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(2),
                                    child: Icon(
                                      mark,
                                      size: 12,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        IconButton(
          tooltip: '下一张',
          onPressed:
              widget.position >= 0 &&
                  widget.position + 1 < widget.count &&
                  widget.onSelect != null
              ? () => widget.onSelect!(widget.position + 1)
              : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
  );
}
