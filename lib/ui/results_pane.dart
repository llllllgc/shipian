import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../core/models.dart';
import 'palette.dart';

class ResultsPane extends StatelessWidget {
  const ResultsPane({
    super.key,
    required this.plan,
    required this.indices,
    required this.selectedIndex,
    required this.onSelect,
    required this.archivedJpgs,
    required this.onOpen,
  });
  final MatchPlan plan;
  final List<int> indices;
  final int? selectedIndex;
  final ValueChanged<int> onSelect, onOpen;
  final Map<String, String> archivedJpgs;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Palette.line)),
        ),
        child: const Row(
          children: [
            SizedBox(width: 52),
            Expanded(child: Text('JPG')),
            SizedBox(width: 10),
            Expanded(child: Text('RAW')),
            SizedBox(width: 88, child: Text('状态')),
          ],
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: indices.length,
          itemExtent: 66,
          itemBuilder: (context, i) => _row(plan.items[indices[i]], indices[i]),
        ),
      ),
    ],
  );

  Widget _row(MatchItem item, int index) {
    final selected = selectedIndex == index;
    final rawText =
        item.raw?.name ??
        (item.candidates.isEmpty ? '—' : '${item.candidates.length} 个候选');
    return Material(
      color: selected ? Palette.selection : Colors.transparent,
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons == kPrimaryButton) onSelect(index);
        },
        child: InkWell(
          onTap: () => onSelect(index),
          onDoubleTap: () => onOpen(index),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Palette.line, width: .6),
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Image.file(
                      File(archivedJpgs[item.jpg.path] ?? item.jpg.path),
                      fit: BoxFit.cover,
                      cacheWidth: 100,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: Color(0xFFE0E4E6),
                        child: Icon(
                          Icons.image_outlined,
                          size: 17,
                          color: Palette.muted,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.jpg.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        formatBytes(item.jpg.size),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Palette.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: Tooltip(
                    message: item.raw?.relativePath ?? rawText,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          rawText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: item.raw == null
                                ? Palette.muted
                                : Palette.ink,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          item.raw == null ? '—' : formatBytes(item.raw!.size),
                          style: const TextStyle(
                            fontSize: 10,
                            color: Palette.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: 88, child: StatusLabel(item: item)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class StatusLabel extends StatelessWidget {
  const StatusLabel({super.key, required this.item});
  final MatchItem item;
  @override
  Widget build(BuildContext context) {
    final color = switch (item.status) {
      MatchStatus.matched => Palette.control,
      MatchStatus.missing => Palette.muted,
      MatchStatus.conflict => Palette.amber,
    };
    final text = switch (item.status) {
      MatchStatus.matched => item.manuallyChosen ? '已指定' : '已匹配',
      MatchStatus.missing => '未找到',
      MatchStatus.conflict => '待确认',
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          item.status == MatchStatus.matched
              ? Icons.check_circle_outline
              : item.status == MatchStatus.conflict
              ? Icons.help_outline
              : Icons.remove_circle_outline,
          size: 13,
          color: color,
        ),
        const SizedBox(width: 5),
        Text(text, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }
}
