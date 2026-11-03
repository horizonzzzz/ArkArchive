import 'package:flutter/material.dart';

import 'app_theme.dart';

class ArchiveHeading extends StatelessWidget {
  const ArchiveHeading(this.title, this.subtitle, {super.key, this.trailing});
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Container(
        width: 3,
        height: 36,
        margin: const EdgeInsets.only(right: 12),
        color: AppColors.cyan,
      ),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 10,
                letterSpacing: 2,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
      ?trailing,
    ],
  );
}

class ArchivePanel extends StatelessWidget {
  const ArchivePanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: AppColors.panel,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(3),
    ),
    child: child,
  );
}

class ArchiveTag extends StatelessWidget {
  const ArchiveTag(this.label, {super.key, this.color = AppColors.secondary});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .09),
      border: Border.all(color: color.withValues(alpha: .25)),
    ),
    child: Text(label, style: TextStyle(fontSize: 11, color: color)),
  );
}

class PreviewNotice extends StatelessWidget {
  const PreviewNotice({
    super.key,
    this.text = '功能预览 · 本页操作仅演示界面，不会下载、删除或保存设置。',
  });
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.yellow.withValues(alpha: .06),
      border: const Border(left: BorderSide(color: AppColors.yellow, width: 2)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 17, color: AppColors.yellow),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.secondary,
              height: 1.6,
            ),
          ),
        ),
      ],
    ),
  );
}

class ArchiveEmpty extends StatelessWidget {
  const ArchiveEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.muted),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.secondary,
                height: 1.7,
              ),
            ),
            if (action != null)
              Padding(padding: const EdgeInsets.only(top: 20), child: action),
          ],
        ),
      ),
    ),
  );
}

void showPreviewMessage(BuildContext context, String feature) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('$feature尚未接入，本次仅预览界面。')));
}

Future<void> showCachePreviewConfirmation(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空素材缓存'),
        content: const Text('此处预览清理确认流程。缓存管理尚未接入，确认后不会删除任何文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              showPreviewMessage(context, '缓存清理');
            },
            child: const Text(
              '确认预览',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
