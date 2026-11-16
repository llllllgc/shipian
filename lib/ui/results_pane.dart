import 'dart:io';
import 'package:flutter/material.dart';
import '../core/models.dart';
import 'palette.dart';

class ResultsPane extends StatefulWidget {
  const ResultsPane({
    super.key,
    required this.plan,
    required this.busy,
    required this.scanMessage,
    required this.selectedIndex,
    required this.filter,
    required this.query,
    required this.onFilter,
    required this.onQuery,
    required this.onSelect,
    this.archivedJpgs = const {},
  });
  final MatchPlan? plan;
  final bool busy;
  final String scanMessage;
  final int? selectedIndex;
  final String filter, query;
  final ValueChanged<String> onFilter, onQuery;
  final ValueChanged<int> onSelect;
  final Map<String, String> archivedJpgs;
  @override
  State<ResultsPane> createState() => _ResultsPaneState();
}

class _ResultsPaneState extends State<ResultsPane> {
  late final search = TextEditingController(text: widget.query);
  @override
  void didUpdateWidget(ResultsPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (search.text != widget.query) search.text = widget.query;
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final indices = plan == null
        ? <int>[]
        : [
            for (var i = 0; i < plan.items.length; i++)
              if (_include(plan.items[i])) i,
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (plan != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                for (final label in ['全部', '已匹配', '未找到', '待确认'])
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: _filter(label),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 34,
                    child: TextField(
                      controller: search,
                      onChanged: widget.onQuery,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        hintText: '搜索',
                        prefixIcon: Icon(Icons.search, size: 17),
                        fillColor: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (plan != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: Palette.line),
                bottom: BorderSide(color: Palette.line),
              ),
            ),
            child: const Row(
              children: [
                SizedBox(width: 52),
                Expanded(
                  flex: 3,
                  child: Text(
                    'JPG',
                    style: TextStyle(fontSize: 11, color: Palette.muted),
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: Text(
                    'RAW',
                    style: TextStyle(fontSize: 11, color: Palette.muted),
                  ),
                ),
                SizedBox(
                  width: 88,
                  child: Text(
                    '状态',
                    style: TextStyle(fontSize: 11, color: Palette.muted),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: widget.busy
              ? _scanning()
              : plan == null
              ? _empty()
              : indices.isEmpty
              ? const Center(
                  child: Text(
                    '无结果',
                    style: TextStyle(color: Palette.muted, fontSize: 13),
                  ),
                )
              : ListView.builder(
                  itemCount: indices.length,
                  itemExtent: 66,
                  itemBuilder: (context, position) =>
                      _row(plan.items[indices[position]], indices[position]),
                ),
        ),
      ],
    );
  }

  bool _include(MatchItem item) {
    if (widget.filter == '已匹配' && item.status != MatchStatus.matched) {
      return false;
    }
    if (widget.filter == '未找到' && item.status != MatchStatus.missing) {
      return false;
    }
    if (widget.filter == '待确认' && item.status != MatchStatus.conflict) {
      return false;
    }
    final term = widget.query.trim().toLowerCase();
    return term.isEmpty ||
        item.jpg.relativePath.toLowerCase().contains(term) ||
        item.candidates.any((c) => c.relativePath.toLowerCase().contains(term));
  }

  Widget _filter(String label) {
    final active = label == widget.filter;
    final count = label == '全部'
        ? widget.plan!.items.length
        : widget.plan!.count(switch (label) {
            '已匹配' => MatchStatus.matched,
            '未找到' => MatchStatus.missing,
            _ => MatchStatus.conflict,
          });
    return Material(
      color: active ? Palette.ink : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => widget.onFilter(label),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: active ? Colors.white : Palette.muted,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  color: active ? Colors.white70 : Palette.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(MatchItem item, int index) {
    final selected = widget.selectedIndex == index;
    final rawText =
        item.raw?.name ??
        (item.candidates.isEmpty ? '—' : '${item.candidates.length} 个候选');
    return Material(
      color: selected ? const Color(0xFFE8EFEB) : Colors.transparent,
      child: InkWell(
        onTap: () => widget.onSelect(index),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Palette.line, width: .6)),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Image.file(
                    File(widget.archivedJpgs[item.jpg.path] ?? item.jpg.path),
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
                          color: item.raw == null ? Palette.muted : Palette.ink,
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
    );
  }

  Widget _scanning() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: 20),
        Text(
          widget.scanMessage,
          style: const TextStyle(fontSize: 13, color: Palette.muted),
        ),
      ],
    ),
  );

  Widget _empty() => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.photo_library_outlined, size: 38, color: Color(0xFFB3BBC1)),
        SizedBox(height: 14),
        Text(
          '选择 JPG 和 RAW 文件夹',
          style: TextStyle(fontSize: 13, color: Palette.muted),
        ),
      ],
    ),
  );
}

class StatusLabel extends StatelessWidget {
  const StatusLabel({super.key, required this.item});
  final MatchItem item;
  @override
  Widget build(BuildContext context) {
    final color = switch (item.status) {
      MatchStatus.matched => Palette.green,
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
