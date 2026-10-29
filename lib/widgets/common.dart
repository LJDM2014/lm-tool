import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/pdf_core.dart';
import '../services/platform_io.dart';

/// 人类可读的文件大小。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

/// 文件大小文本；大小未知时给出提示。
String sizeLabel(int? size) =>
    size == null ? '大小未知' : formatBytes(size);

/// 文件信息片段（含开括号）：如 "（2.3 MB"；大小未知时给出提示。
String sizePart(int? size) =>
    size == null ? '（大小未知' : '（${formatBytes(size)}';

/// 是否已满足输出条件（Web 端无输出目录概念，始终就绪）。
bool get outputReady => !hasFileSystem || AppSettings.outputDir.value != null;

/// 带标题的分区卡片。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// 输出目录选择行：桌面显示当前目录 + 选择按钮；Web 提示结果以下载形式保存。
class OutputDirPicker extends StatelessWidget {
  const OutputDirPicker({super.key});

  @override
  Widget build(BuildContext context) {
    if (!hasFileSystem) {
      return Row(
        children: [
          Icon(
            Icons.download_outlined,
            size: 20,
            color: Theme.of(context).colorScheme.secondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '处理完成后，结果将以浏览器下载的形式保存',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
        ],
      );
    }
    return ValueListenableBuilder<String?>(
      valueListenable: AppSettings.outputDir,
      builder: (context, dir, _) {
        return Row(
          children: [
            Icon(
              Icons.folder_outlined,
              size: 20,
              color: Theme.of(context).colorScheme.secondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                dir ?? '尚未选择输出目录',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: dir != null
                      ? null
                      : Theme.of(context).hintColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final path = await pickOutputDirectory();
                if (path != null) AppSettings.outputDir.value = path;
              },
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('选择'),
            ),
          ],
        );
      },
    );
  }
}

/// 任务运行中的进度条 + 取消按钮。
class JobProgressBar extends StatelessWidget {
  const JobProgressBar({super.key, required this.status, required this.onCancel});

  final String status;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(status)),
            TextButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.close, size: 18),
              label: const Text('取消'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const LinearProgressIndicator(minHeight: 3),
      ],
    );
  }
}

/// 结果视图：输出列表（桌面显示大小 + 打开所在文件夹；Web 提供逐文件下载）。
class ResultView extends StatelessWidget {
  const ResultView({super.key, required this.outputs});

  final List<PdfOutput> outputs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final o in outputs)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(
                  o.name.toLowerCase().endsWith('.png')
                      ? Icons.image_outlined
                      : Icons.picture_as_pdf_outlined,
                  size: 18,
                  color: o.name.toLowerCase().endsWith('.png')
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${o.name}（${sizeLabel(o.size)}）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!hasFileSystem)
                  IconButton(
                    onPressed: () => downloadOutput(o),
                    icon: const Icon(Icons.download_outlined, size: 20),
                    tooltip: '下载文件',
                  ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        if (hasFileSystem)
          OutlinedButton.icon(
            onPressed: () => openOutputFolder(),
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            label: const Text('打开所在文件夹'),
          )
        else
          Text(
            '点击文件右侧的下载按钮保存到本地',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.hintColor,
            ),
          ),
      ],
    );
  }
}

/// 拖拽导入区：把文件拖入窗口时高亮提示，松手后按扩展名过滤并回调。
class PdfDropZone extends StatefulWidget {
  const PdfDropZone({
    super.key,
    required this.child,
    required this.onDocsDropped,
    this.extensions = const ['pdf'],
    this.enabled = true,
  });

  final Widget child;
  final ValueChanged<List<PickedDoc>> onDocsDropped;

  /// 允许拖入的文件扩展名（小写，不含点）。
  final List<String> extensions;
  final bool enabled;

  @override
  State<PdfDropZone> createState() => _PdfDropZoneState();
}

class _PdfDropZoneState extends State<PdfDropZone> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) async {
        setState(() => _dragging = false);
        final docs = await docsFromDrop(details.files, widget.extensions);
        if (docs.isNotEmpty) widget.onDocsDropped(docs);
      },
      child: Stack(
        children: [
          widget.child,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.08),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Chip(
                    avatar: Icon(
                      Icons.file_download_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    label: const Text('松开以添加文件'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
