import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/photo_preview.dart';
import 'photo_viewer.dart';
import 'palette.dart';
import 'results_pane.dart';

class PreviewPane extends StatelessWidget {
  const PreviewPane({
    super.key,
    required this.plan,
    required this.index,
    required this.busy,
    required this.onChoose,
    required this.service,
    this.archivedRaws = const {},
    this.onExpand,
  });
  final MatchPlan? plan;
  final int? index;
  final bool busy;
  final ValueChanged<String?> onChoose;
  final PhotoPreviewService service;
  final Map<String, String> archivedRaws;
  final ValueChanged<String>? onExpand;

  @override
  Widget build(BuildContext context) {
    final selected = index;
    final item = plan == null || selected == null
        ? null
        : plan!.items[selected];
    if (item == null) return const SizedBox.shrink();
    return ColoredBox(
      color: Palette.surface,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '配对信息',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 20),
          SelectableText(
            item.jpg.name,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          if (item.jpg.relativePath != item.jpg.name)
            Text(
              item.jpg.relativePath,
              style: const TextStyle(fontSize: 12, color: Palette.muted),
            ),
          const SizedBox(height: 4),
          Text(
            formatBytes(item.jpg.size),
            style: const TextStyle(fontSize: 12, color: Palette.muted),
          ),
          const SizedBox(height: 12),
          StatusLabel(item: item),
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 16),
          _label(item.candidates.length > 1 ? '选择 RAW' : '对应 RAW'),
          const SizedBox(height: 10),
          if (item.candidates.isEmpty)
            const Text(
              '未找到 RAW',
              style: TextStyle(fontSize: 12, color: Palette.muted),
            ),
          for (final raw in item.candidates)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _candidate(context, raw, item),
            ),
          if (item.manuallyChosen)
            TextButton(
              onPressed: busy ? null : () => onChoose(null),
              child: const Text('跳过'),
            ),
        ],
      ),
    );
  }

  Widget _label(String value) => Text(
    value,
    style: const TextStyle(
      fontSize: 12,
      color: Palette.ink,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _candidate(BuildContext context, PhotoFile raw, MatchItem item) {
    final selected = item.raw?.path == raw.path;
    return Material(
      color: selected ? Palette.background : Palette.background,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: busy || item.candidates.length == 1
            ? null
            : () => onChoose(raw.path),
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? Palette.selection : Palette.line,
            ),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 15,
                    color: selected ? Palette.control : Palette.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      raw.relativePath,
                      style: const TextStyle(fontSize: 12, height: 1.6),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '预览 RAW',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      final path = archivedRaws[raw.path] ?? raw.path;
                      if (onExpand != null) {
                        onExpand!(path);
                      } else {
                        showPhotoViewer(
                          context,
                          service: service,
                          entries: [PreviewEntry(path)],
                        );
                      }
                    },
                    icon: const Icon(
                      Icons.visibility_outlined,
                      size: 17,
                      color: Palette.muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                formatBytes(raw.size),
                style: const TextStyle(fontSize: 10, color: Palette.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
