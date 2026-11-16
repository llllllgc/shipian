import 'dart:math';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/task_store.dart';
import 'palette.dart';

typedef TaskAction = ({String action, String? id});

Future<TaskAction?> showTaskHistory(
  BuildContext context,
  List<TaskSummary> tasks,
) => showDialog<TaskAction>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('任务'),
    content: SizedBox(
      width: 520,
      height: min(380, max(90, tasks.length * 72)).toDouble(),
      child: tasks.isEmpty
          ? const Center(
              child: Text('暂无任务', style: TextStyle(color: Palette.muted)),
            )
          : ListView.builder(
              itemCount: tasks.length,
              itemBuilder: (context, index) {
                final task = tasks[index];
                final date = task.updatedAt.toLocal().toString().substring(
                  0,
                  16,
                );
                final status = switch (task.phase) {
                  'idle' => '待匹配',
                  'review' => '待归档',
                  'copying' => '待继续',
                  'cleaning' => '待继续',
                  'restoring' => '待继续',
                  'cleaned' => '已清理',
                  'restored' => '已恢复',
                  'error' => '无法读取',
                  _ => '已保存',
                };
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '$date · $status',
                    style: const TextStyle(fontSize: 12, color: Palette.muted),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 17),
                  onTap: () =>
                      Navigator.pop(context, (action: 'open', id: task.id)),
                );
              },
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, (action: 'import', id: null)),
        child: const Text('打开归档'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, (action: 'new', id: null)),
        child: const Text('新任务'),
      ),
    ],
  ),
);

Future<Map<String, ConflictAction>?> showRestoreConfirmation(
  BuildContext context,
  RestorePreview preview,
) {
  final decisions = <String, ConflictAction>{};
  final conflicts = {
    for (final c in preview.conflicts) c.receipt.source.path: c,
  };
  final raw = preview.targets.where((r) => r.kind == PhotoKind.raw).length;
  return showDialog<Map<String, ConflictAction>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('恢复原位置'),
        content: SizedBox(
          width: 590,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$raw RAW + ${preview.targets.length - raw} JPG'),
              const SizedBox(height: 8),
              const Text(
                '归档保留；同名文件不覆盖。',
                style: TextStyle(fontSize: 12, color: Palette.muted),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: min(
                  320,
                  max(90, preview.targets.length * 70),
                ).toDouble(),
                child: ListView.builder(
                  itemCount: preview.targets.length,
                  itemBuilder: (context, index) {
                    final receipt = preview.targets[index];
                    final path = receipt.source.path;
                    final conflict = conflicts[path];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectableText(
                                  path,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                if (conflict != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 5),
                                    child: Text(
                                      '原位置 ${conflict.existingBytes < 0 ? '目录或链接' : formatBytes(conflict.existingBytes)} / 归档 ${formatBytes(receipt.source.size)}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Palette.amber,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (conflict != null) ...[
                            const SizedBox(width: 16),
                            DropdownButton<ConflictAction>(
                              value: decisions[path] ?? ConflictAction.skip,
                              underline: const SizedBox(),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Palette.ink,
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: ConflictAction.skip,
                                  child: Text('跳过'),
                                ),
                                DropdownMenuItem(
                                  value: ConflictAction.keepBoth,
                                  child: Text('另存副本'),
                                ),
                              ],
                              onChanged: (value) =>
                                  update(() => decisions[path] = value!),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: preview.targets.isEmpty
                ? null
                : () => Navigator.pop(context, decisions),
            child: const Text('恢复'),
          ),
        ],
      ),
    ),
  );
}
