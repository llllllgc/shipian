import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../core/converter.dart';
import 'palette.dart';

class ConversionSettings {
  const ConversionSettings(this.request, this.selectedOnly);
  final ConversionRequest request;
  final bool selectedOnly;
}

Future<ConversionSettings?> showConversionDialog(
  BuildContext context, {
  required int selectedCount,
  String? inputRoot,
  String? outputRoot,
}) => showDialog<ConversionSettings>(
  context: context,
  builder: (_) => _ConversionDialog(
    selectedCount: selectedCount,
    inputRoot: inputRoot,
    outputRoot: outputRoot,
  ),
);

class _ConversionDialog extends StatefulWidget {
  const _ConversionDialog({
    required this.selectedCount,
    this.inputRoot,
    this.outputRoot,
  });
  final int selectedCount;
  final String? inputRoot, outputRoot;
  @override
  State<_ConversionDialog> createState() => _ConversionDialogState();
}

class _ConversionDialogState extends State<_ConversionDialog> {
  late bool selectedOnly = widget.selectedCount > 0;
  late String? input = widget.inputRoot, output = widget.outputRoot;
  ImageFormat format = ImageFormat.jpg;
  int quality = 90;
  bool picking = false;
  String? error;

  Future<void> choose(bool source) async {
    setState(() {
      picking = true;
      error = null;
    });
    try {
      final path = await getDirectoryPath(
        initialDirectory: source ? input : output,
        confirmButtonText: source ? '选择 RAW 文件夹' : '保存到这里',
      );
      if (mounted && path != null) {
        setState(() {
          if (source) {
            input = path;
          } else {
            output = path;
          }
        });
      }
    } catch (exception) {
      if (mounted) setState(() => error = '无法打开文件夹：$exception');
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Widget folder(String label, String? path, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Palette.muted)),
        const SizedBox(height: 6),
        OutlinedButton(
          onPressed: picking ? null : onTap,
          child: Row(
            children: [
              const Icon(Icons.folder_outlined, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  path ?? '选择文件夹',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const Icon(Icons.chevron_right, size: 16),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !picking,
    child: AlertDialog(
      title: const Text('RAW 转图片'),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.selectedCount > 0) ...[
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: true,
                      label: Text('精选 ${widget.selectedCount} 张'),
                    ),
                    const ButtonSegment(value: false, label: Text('整个文件夹')),
                  ],
                  selected: {selectedOnly},
                  onSelectionChanged: picking
                      ? null
                      : (value) => setState(() => selectedOnly = value.single),
                ),
                const SizedBox(height: 20),
              ],
              if (!selectedOnly) folder('RAW 文件夹', input, () => choose(true)),
              folder('保存位置', output, () => choose(false)),
              Row(
                children: [
                  const Text(
                    '格式',
                    style: TextStyle(fontSize: 12, color: Palette.muted),
                  ),
                  const Spacer(),
                  SegmentedButton<ImageFormat>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: ImageFormat.jpg, label: Text('JPG')),
                      ButtonSegment(value: ImageFormat.png, label: Text('PNG')),
                    ],
                    selected: {format},
                    onSelectionChanged: picking
                        ? null
                        : (value) => setState(() => format = value.single),
                  ),
                ],
              ),
              if (format == ImageFormat.jpg) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      '画质',
                      style: TextStyle(fontSize: 12, color: Palette.muted),
                    ),
                    const Spacer(),
                    DropdownButton<int>(
                      value: quality,
                      underline: const SizedBox(),
                      items: [80, 90, 95, 100]
                          .map(
                            (q) =>
                                DropdownMenuItem(value: q, child: Text('$q')),
                          )
                          .toList(),
                      onChanged: picking
                          ? null
                          : (value) => setState(() => quality = value!),
                    ),
                  ],
                ),
              ],
              if (error != null)
                Text(
                  error!,
                  style: const TextStyle(fontSize: 12, color: Palette.red),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: picking ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed:
              picking || output == null || (!selectedOnly && input == null)
              ? null
              : () => Navigator.pop(
                  context,
                  ConversionSettings(
                    ConversionRequest(
                      outputRoot: output!,
                      inputRoot: input,
                      format: format,
                      quality: quality,
                    ),
                    selectedOnly,
                  ),
                ),
          child: const Text('开始转换'),
        ),
      ],
    ),
  );
}
