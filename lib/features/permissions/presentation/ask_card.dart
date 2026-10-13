import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../domain/permission_ask.dart';

/// Hairline indent between rows: past the gutter, the icon and its gap, so the
/// rule starts under the text rather than under the icon.
const double _dividerIndent = AppTokens.gutter + 22 + 14;

/// Every permission ask as one ruled list: icon, name, and either an Allow
/// button or a tick.
///
/// The name is the row. A reason line appears only on the ask whose name does
/// not say what it is for, plus at most one extra word: "Required", or "Turn
/// on in Settings" once Android stops showing the dialog, and the one how-to a
/// user genuinely needs to get past a locked switch.
class AskList extends StatelessWidget {
  const AskList({
    super.key,
    required this.asks,
    required this.onRequest,
    required this.isBlocked,
    required this.isBusy,
  });

  final List<PermissionAsk> asks;
  final void Function(PermissionAsk ask) onRequest;
  final bool Function(PermissionAsk ask) isBlocked;
  final bool Function(PermissionAsk ask) isBusy;

  @override
  Widget build(BuildContext context) => ListGroup(
    dividerIndent: _dividerIndent,
    children: [
      for (final ask in asks)
        AskRow(
          ask: ask,
          blocked: isBlocked(ask),
          busy: isBusy(ask),
          onRequest: () => onRequest(ask),
        ),
    ],
  );
}

/// One permission: tap the row or its button to ask.
class AskRow extends StatelessWidget {
  const AskRow({
    super.key,
    required this.ask,
    required this.onRequest,
    this.blocked = false,
    this.busy = false,
  });

  final PermissionAsk ask;
  final VoidCallback onRequest;

  /// Android will no longer show the dialog; only Settings can grant it.
  final bool blocked;
  final bool busy;

  /// Asks Android cannot answer in a dialog — they open a settings screen.
  bool get _opensSettings =>
      blocked ||
      ask.kind == AskKind.backgroundActivity ||
      ask.kind == AskKind.overlayWindow ||
      ask.kind == AskKind.notificationListener ||
      ask.kind == AskKind.autostart;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final tappable = !busy && !ask.granted;

    // One short line at most.
    final String? note = ask.granted
        ? null
        : blocked
        ? 'Turn on in Settings'
        : ask.essential
        ? 'Required'
        : null;

    // The one row whose switch can be locked by Android itself (restricted
    // settings for sideloaded apps), so it carries the way out under its
    // "Required".
    final String? hint =
        !ask.granted && ask.kind == AskKind.notificationListener
        ? ask.howTo
        : null;

    return Semantics(
      button: tappable,
      label:
          '${ask.title}, ${ask.granted ? "allowed" : (note ?? "not allowed")}',
      excludeSemantics: true,
      child: InkWell(
        onTap: tappable ? onRequest : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 68),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.gutter,
              14,
              AppTokens.gutter - 4,
              14,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(ask.icon, size: 22, color: z.ink2),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        ask.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.bodyStrong.copyWith(
                          color: ask.granted ? z.ink2 : z.ink,
                        ),
                      ),
                      if (ask.why != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          ask.why!,
                          style: AppType.label.copyWith(
                            color: z.ink2,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                      if (note != null) ...[
                        const SizedBox(height: 8),
                        if (blocked)
                          Text(
                            note,
                            style: AppType.captionStrong.copyWith(
                              color: z.ink3,
                            ),
                          )
                        else
                          StatusPill(label: note, color: z.warn),
                      ],
                      if (hint != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          hint,
                          style: AppType.caption.copyWith(color: z.ink3),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                AnimatedSwitcher(
                  duration: AppTokens.medium,
                  child: ask.granted
                      ? Padding(
                          key: const ValueKey('granted'),
                          padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
                          child: Icon(
                            Icons.check_rounded,
                            color: z.ok,
                            size: 22,
                            semanticLabel: 'Allowed',
                          ),
                        )
                      : ZButton(
                          key: const ValueKey('ask'),
                          label: _opensSettings ? 'Settings' : 'Allow',
                          size: ZButtonSize.compact,
                          expand: false,
                          loading: busy,
                          onPressed: tappable ? onRequest : null,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder shown while the first permission read is in flight.
class AskSkeletonList extends StatelessWidget {
  const AskSkeletonList({super.key, this.rows = 5});

  final int rows;

  @override
  Widget build(BuildContext context) => ShimmerScope(
    child: ListGroup(
      dividerIndent: _dividerIndent,
      children: [
        for (var i = 0; i < rows; i++)
          const Padding(
            padding: EdgeInsets.fromLTRB(
              AppTokens.gutter,
              16,
              AppTokens.gutter - 4,
              16,
            ),
            child: Row(
              children: [
                Skeleton(width: 22, height: 22),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Skeleton(width: 140, height: 13),
                      SizedBox(height: 8),
                      Skeleton(width: 200, height: 11),
                    ],
                  ),
                ),
                Skeleton(width: 72, height: 40, radius: AppTokens.r10),
              ],
            ),
          ),
      ],
    ),
  );
}
