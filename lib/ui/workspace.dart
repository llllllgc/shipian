import 'package:flutter/material.dart';
import 'palette.dart';

enum WorkspaceMode {
  culling('选片整理', Icons.photo_library_outlined),
  archive('匹配归档', Icons.inventory_2_outlined);

  const WorkspaceMode(this.label, this.icon);
  final String label;
  final IconData icon;
}

class WorkspaceFrame extends StatelessWidget {
  const WorkspaceFrame({
    super.key,
    required this.mode,
    required this.onSwitch,
    required this.sidebar,
    required this.tools,
    required this.title,
    required this.content,
    this.toolbar = const [],
    this.notice,
    this.footer,
  });
  final WorkspaceMode mode;
  final VoidCallback? onSwitch;
  final Widget sidebar, tools, content;
  final String title;
  final List<Widget> toolbar;
  final Widget? notice, footer;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Row(
      children: [
        Container(
          width: MediaQuery.sizeOf(context).width < 1150 ? 176 : 208,
          color: Palette.sidebar,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(
                height: 60,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Image(
                        image: AssetImage('assets/brand/shipian-mark.png'),
                        width: 22,
                        height: 22,
                        color: Palette.ink,
                        excludeFromSemantics: true,
                      ),
                      SizedBox(width: 10),
                      Text(
                        '拾片',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              for (final entry in WorkspaceMode.values)
                SidebarRow(
                  label: entry.label,
                  icon: entry.icon,
                  selected: entry == mode,
                  onTap: entry == mode ? () {} : onSwitch,
                ),
              const SizedBox(height: 20),
              Expanded(child: SingleChildScrollView(child: sidebar)),
              const Divider(),
              const SizedBox(height: 6),
              tools,
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: const BoxDecoration(
                  color: Palette.surface,
                  border: Border(bottom: BorderSide(color: Palette.line)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: title,
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    ...toolbar,
                  ],
                ),
              ),
              ?notice,
              Expanded(child: content),
              ?footer,
            ],
          ),
        ),
      ],
    ),
  );
}

class SidebarHeading extends StatelessWidget {
  const SidebarHeading(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Palette.muted,
      ),
    ),
  );
}

class SidebarRow extends StatelessWidget {
  const SidebarRow({
    super.key,
    required this.label,
    required this.icon,
    this.onTap,
    this.selected = false,
    this.detail,
    this.count,
    this.tooltip,
  });
  final String label;
  final String? detail, tooltip;
  final int? count;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final row = Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? Palette.selection : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 17, color: Palette.ink),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      if (detail != null)
                        Text(
                          detail!,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Palette.muted,
                          ),
                        ),
                    ],
                  ),
                ),
                if (count != null)
                  Text(
                    '$count',
                    style: const TextStyle(fontSize: 12, color: Palette.muted),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? row : Tooltip(message: tooltip!, child: row);
  }
}

class WorkspaceEmpty extends StatelessWidget {
  const WorkspaceEmpty({
    super.key,
    required this.title,
    required this.hint,
    this.action,
  });
  final String title, hint;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.photo_library_outlined,
            size: 38,
            color: Palette.muted,
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Palette.muted),
          ),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}
