import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../services/app_settings.dart';

/// 人类可读的文件大小。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

/// 安全读取文件大小；文件不存在或不可读时返回 null（不抛异常）。
int? safeFileLength(File f) {
  try {
    return f.existsSync() ? f.lengthSync() : null;
  } catch (_) {
    return null;
  }
}

/// 文件信息片段（含开括号）：如 "（2.3 MB"；文件缺失时给出提示。
String fileSizePart(File f) {
  final size = safeFileLength(f);
  return size == null ? '（文件已被移动或删除' : '（${formatBytes(size)}';
}

/// 文件大小文本；文件不存在时返回提示。
String fileSizeLabel(File f) {
  final size = safeFileLength(f);
  return size == null ? '文件已被移动或删除' : formatBytes(size);
}

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

/// 输出目录选择行：显示当前目录 + 选择按钮。
class OutputDirPicker extends StatelessWidget {
  const OutputDirPicker({super.key});

  @override
  Widget build(BuildContext context) {
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
                final path = await FilePicker.getDirectoryPath(
                  dialogTitle: '选择输出目录',
                );
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

/// 结果视图：输出文件列表 + 打开所在文件夹按钮。
class ResultView extends StatelessWidget {
  const ResultView({super.key, required this.files});

  final List<File> files;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final f in files)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(
                  Icons.picture_as_pdf_outlined,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Tooltip(
                    message: f.path,
                    child: Builder(
                      builder: (context) {
                        final size = safeFileLength(f);
                        final label = size == null
                            ? '${f.uri.pathSegments.last}（文件已被移动或删除）'
                            : '${f.uri.pathSegments.last}'
                                '（${formatBytes(size)}）';
                        return Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: size == null
                              ? TextStyle(
                                  color: theme.hintColor,
                                  fontStyle: FontStyle.italic,
                                )
                              : null,
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: () =>
              OpenFilex.open(files.first.parent.path),
          icon: const Icon(Icons.folder_open_outlined, size: 18),
          label: const Text('打开所在文件夹'),
        ),
      ],
    );
  }
}
