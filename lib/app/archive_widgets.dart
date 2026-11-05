import 'package:flutter/material.dart';

import 'app_theme.dart';

class ArchiveHeading extends StatelessWidget {
  const ArchiveHeading(
    this.title, {
    super.key,
    this.subtitle = '',
    this.leading,
    this.trailing,
  });
  final String title;
  final String subtitle;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (leading != null) ...[leading!, const SizedBox(width: 12)],
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
                height: 1.3,
              ),
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.subtext,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
      ),
      if (trailing != null) ...[const SizedBox(width: 12), trailing!],
    ],
  );
}

/// 顶部区域独立于列表滚动，避免固定高度截断放大的系统文字。
class ArchivePageHeader extends StatelessWidget {
  const ArchivePageHeader({
    super.key,
    required this.title,
    this.subtitle = '',
    this.leading,
    this.trailing,
    this.bottom,
    this.maxWidth = double.infinity,
  });
  final String title;
  final String subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget? bottom;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: AppColors.canvas,
      border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
    ),
    child: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ArchiveHeading(
                title,
                subtitle: subtitle,
                leading: leading,
                trailing: trailing,
              ),
              if (bottom != null) ...[const SizedBox(height: 14), bottom!],
            ],
          ),
        ),
      ),
    ),
  );
}

class ArchivePanel extends StatelessWidget {
  const ArchivePanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.panel,
    shape: const RoundedRectangleBorder(
      side: BorderSide(color: AppColors.borderSubtle),
    ),
    child: Padding(padding: padding, child: child),
  );
}

class ArchiveTag extends StatelessWidget {
  const ArchiveTag(this.label, {super.key, this.color = AppColors.secondary});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.zero,
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: color,
      ),
    ),
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
