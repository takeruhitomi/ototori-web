import 'package:flutter/material.dart';
import 'theme.dart';

/// HIG inset-grouped section: optional header and footer around rounded rows.
class GroupedSection extends StatelessWidget {
  const GroupedSection({super.key, this.header, this.footer, required this.children,
    this.margin = const EdgeInsets.fromLTRB(16, 8, 16, 16)});
  final String? header;
  final String? footer;
  final List<Widget> children;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(Padding(padding: const EdgeInsets.only(left: 16), child: Divider(height: 0.5, color: c.separator)));
      rows.add(children[i]);
    }
    return Padding(padding: margin, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (header != null) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: Text(header!, style: text.titleSmall!.copyWith(color: c.secondaryLabel))),
      Material(color: c.surface, borderRadius: BorderRadius.circular(14), clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows)),
      if (footer != null) Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Text(footer!, style: text.bodySmall)),
    ]));
  }
}

/// Round part badge (S, A, T1, Pf…) in the part's identifying color.
class PartBadge extends StatelessWidget {
  const PartBadge({super.key, required this.id, required this.name, this.size = 34, this.dimmed = false});
  final String id, name;
  final double size;
  final bool dimmed;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final color = c.parts.forPart(id, name);
    final abbr = partAbbreviation(id, name);
    return Container(
      width: size, height: size, alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle,
        color: dimmed ? Colors.transparent : color,
        border: dimmed ? Border.all(color: color, width: 1.5) : null),
      child: Text(abbr, maxLines: 1, style: TextStyle(fontSize: size * (abbr.length > 1 ? 0.36 : 0.44),
        fontWeight: FontWeight.w700, color: dimmed ? color : Colors.white, height: 1)),
    );
  }
}

/// Centered message with one next step, for empty and error states.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, required this.message, this.icon, this.image, this.actions = const []});
  final String title, message;
  final IconData? icon;
  final Widget? image;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    return Center(child: SingleChildScrollView(padding: const EdgeInsets.all(32), child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (image != null) image!,
        if (image == null && icon != null) Icon(icon, size: 56, color: c.tertiaryLabel),
        const SizedBox(height: 20),
        Text(title, textAlign: TextAlign.center, style: text.headlineSmall),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center, style: text.bodyMedium!.copyWith(color: c.secondaryLabel)),
        if (actions.isNotEmpty) const SizedBox(height: 24),
        for (final a in actions) Padding(padding: const EdgeInsets.only(bottom: 8), child: a),
      ]),
    )));
  }
}

/// The 音鳥 mark (icon foreground) on its navy tile.
class OtotoriMark extends StatelessWidget {
  const OtotoriMark({super.key, this.size = 96});
  final double size;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size * 0.23),
    child: Image.asset('assets/icon/png/play_store_512.png', width: size, height: size,
      cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
      errorBuilder: (context, error, stack) => Container(width: size, height: size, color: OtotoriColors.navy)),
  );
}

/// Bottom sheet with a title row; content scrolls.
Future<T?> showOtotoriSheet<T>(BuildContext context, {required String title, required WidgetBuilder builder,
    bool expand = false, List<Widget> actions = const []}) =>
  showModalBottomSheet<T>(context: context, isScrollControlled: true, useSafeArea: true,
    builder: (context) => _SheetFrame(title: title, expand: expand, actions: actions, child: builder(context)));

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.title, required this.child, required this.expand, required this.actions});
  final String title;
  final Widget child;
  final bool expand;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 0, 8, 4), child: Row(children: [
        Expanded(child: Text(title, style: Theme.of(context).textTheme.headlineSmall)),
        ...actions,
      ])),
      Flexible(child: child),
    ]);
    return expand ? FractionallySizedBox(heightFactor: 0.9, child: body) : body;
  }
}

/// Confirmation for destructive actions (HIG: red option plus Cancel).
Future<bool> confirmDestructive(BuildContext context, {required String title, required String message,
    required String action}) async {
  final c = OtotoriColors.of(context);
  return await showDialog<bool>(context: context, builder: (context) => AlertDialog(
    title: Text(title), content: Text(message),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
      TextButton(onPressed: () => Navigator.pop(context, true),
        style: TextButton.styleFrom(foregroundColor: c.destructive), child: Text(action)),
    ],
  )) ?? false;
}
