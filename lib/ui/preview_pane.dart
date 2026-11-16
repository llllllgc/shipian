import 'dart:io';
import 'package:flutter/material.dart';
import '../core/models.dart';
import 'palette.dart';
import 'results_pane.dart';

class PreviewPane extends StatelessWidget {
  const PreviewPane({
    super.key,
    required this.plan,
    required this.index,
    required this.busy,
    required this.onChoose,
    this.archivedPath,
  });
  final MatchPlan? plan;
  final int? index;
  final bool busy;
  final ValueChanged<String?> onChoose;
  final String? archivedPath;

  @override
  Widget build(BuildContext context) {
    final item = plan != null && index != null && index! < plan!.items.length
        ? plan!.items[index!]
        : null;
    return ColoredBox(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 23, 20, 20),
            child: Text(
              '预览',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          if (item == null)
            const Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(25),
                  child: Text(
                    '选择照片',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.9,
                      color: Palette.muted,
                    ),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: AspectRatio(
                        aspectRatio: 1.4,
                        child: ColoredBox(
                          color: const Color(0xFF1F252A),
                          child: Image.file(
                            File(archivedPath ?? item.jpg.path),
                            fit: BoxFit.contain,
                            cacheWidth: 1000,
                            errorBuilder: (_, _, _) => const Center(
                              child: Text(
                                '无法预览',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 12,
                                  height: 1.8,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      item.jpg.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    StatusLabel(item: item),
                    const SizedBox(height: 12),
                    if (item.jpg.relativePath != item.jpg.name) ...[
                      SelectableText(
                        item.jpg.relativePath,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Palette.muted,
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    Text(
                      formatBytes(item.jpg.size),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Palette.muted,
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Divider(),
                    ),
                    _label(item.candidates.length > 1 ? '选择 RAW' : 'RAW'),
                    const SizedBox(height: 10),
                    if (item.candidates.isEmpty)
                      const Text(
                        '未找到 RAW',
                        style: TextStyle(
                          fontSize: 12,
                          color: Palette.muted,
                          height: 1.9,
                        ),
                      ),
                    if (item.candidates.length > 1)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          '选择一份，或跳过',
                          style: TextStyle(
                            fontSize: 12,
                            color: Palette.amber,
                            height: 1.8,
                          ),
                        ),
                      ),
                    for (final raw in item.candidates)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _candidate(raw, item),
                      ),
                    if (item.manuallyChosen)
                      TextButton(
                        onPressed: busy ? null : () => onChoose(null),
                        child: const Text('跳过'),
                      ),
                  ],
                ),
              ),
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

  Widget _candidate(PhotoFile raw, MatchItem item) {
    final selected = item.raw?.path == raw.path;
    return Material(
      color: selected ? const Color(0xFFF0F6F2) : Palette.background,
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
              color: selected ? const Color(0xFFB9D4C7) : Palette.line,
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
                    color: selected ? Palette.green : Palette.muted,
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
