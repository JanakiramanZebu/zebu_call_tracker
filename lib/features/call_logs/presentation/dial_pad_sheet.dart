import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../call_tracking/data/call_feed.dart';

/// The dial pad bottom sheet: matched contact, the number, a 3×4 keypad and
/// the call button.
///
/// The sheet surface, top radius and drag handle come from the app's
/// bottom-sheet theme; this widget draws only the content, padded up from the
/// system navigation bar.
class DialPadSheet extends ConsumerStatefulWidget {
  const DialPadSheet({super.key, this.initialNumber});

  final String? initialNumber;

  static Future<void> show(BuildContext context, {String? initialNumber}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DialPadSheet(initialNumber: initialNumber),
    );
  }

  @override
  ConsumerState<DialPadSheet> createState() => _DialPadSheetState();
}

class _DialPadSheetState extends ConsumerState<DialPadSheet> {
  String _digits = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialNumber != null && widget.initialNumber!.isNotEmpty) {
      _digits = widget.initialNumber!;
    }
  }

  void _append(String char) {
    HapticFeedback.lightImpact();
    setState(() => _digits += char);
  }

  void _backspace() {
    if (_digits.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  void _clear() {
    if (_digits.isEmpty) return;
    HapticFeedback.mediumImpact();
    setState(() => _digits = '');
  }

  Future<void> _call() async {
    if (_digits.trim().isEmpty) return;
    HapticFeedback.heavyImpact();
    final number = _digits.trim();
    Navigator.of(context).pop();
    final bridge = ref.read(nativeBridgeProvider);
    await bridge.dialNumber(number);
  }

  static final _nonDigits = RegExp(r'[^0-9]');

  String? _findContactName(String number) {
    if (number.length < 3) return null;
    final entries = ref.read(callFeedProvider).value?.entries ?? const [];
    // Runs on every key press, across every loaded call: the pattern and the
    // typed digits are prepared once, not once per row.
    final query = number.replaceAll(_nonDigits, '');
    for (final entry in entries) {
      final raw = entry.row.number?.replaceAll(_nonDigits, '') ?? '';
      if (raw.endsWith(query) || (raw.isNotEmpty && query.endsWith(raw))) {
        if (entry.hasName) {
          return entry.contactName ?? entry.row.cachedName;
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final matchedName = _findContactName(_digits);
    final empty = _digits.isEmpty;

    return BottomSafe(
      minimum: 24,
      // Scrolls only when the sheet is taller than the screen (landscape,
      // large font scale); otherwise it sits at its natural height.
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The contact the typed number belongs to, if one is known. The
            // slot keeps its height so the number does not jump.
            SizedBox(
              height: 20,
              child: AnimatedSwitcher(
                duration: AppTokens.fast,
                child: matchedName != null
                    ? Text(
                        matchedName,
                        key: ValueKey(matchedName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.labelStrong.copyWith(color: z.accent),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            const SizedBox(height: 8),

            // Number display & Backspace row
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  const SizedBox(width: 44), // balance backspace button
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      empty ? 'Enter number' : Fmt.prettyNumber(_digits),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.tabular(
                        TextStyle(
                          fontFamily: AppType.family,
                          fontSize: empty
                              ? 22
                              : (_digits.length > 12 ? 24 : 30),
                          fontWeight: FontWeight.w500,
                          letterSpacing: empty ? 0 : 0.6,
                          height: 1.2,
                        ),
                      ).copyWith(color: empty ? z.ink3 : z.ink),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 44,
                    child: empty
                        ? null
                        : _BackspaceKey(onTap: _backspace, onLongPress: _clear),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: z.line),
            const SizedBox(height: 16),

            // 3x4 Dialpad Grid
            _buildKeypadRow('1', '', '2', 'ABC', '3', 'DEF'),
            const SizedBox(height: 10),
            _buildKeypadRow('4', 'GHI', '5', 'JKL', '6', 'MNO'),
            const SizedBox(height: 10),
            _buildKeypadRow('7', 'PQRS', '8', 'TUV', '9', 'WXYZ'),
            const SizedBox(height: 10),
            _buildKeypadRow('*', '', '0', '+', '#', '', isZeroSpecial: true),
            const SizedBox(height: 16),

            // Action Call Button
            _CallButton(onTap: empty ? null : _call),
          ],
        ),
      ),
    );
  }

  Widget _buildKeypadRow(
    String d1,
    String s1,
    String d2,
    String s2,
    String d3,
    String s3, {
    bool isZeroSpecial = false,
  }) {
    return Row(
      children: [
        Expanded(
          child: _DialKey(digit: d1, subtext: s1, onTap: () => _append(d1)),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: _DialKey(
            digit: d2,
            subtext: s2,
            onTap: () => _append(d2),
            onLongPress: isZeroSpecial ? () => _append('+') : null,
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: _DialKey(digit: d3, subtext: s3, onTap: () => _append(d3)),
        ),
      ],
    );
  }
}

/// Backspace with tap-to-delete and hold-to-clear. Drawn like a [TapIcon] but
/// not one: that has no long press, and a [Tooltip] would claim the long
/// press for itself.
class _BackspaceKey extends StatelessWidget {
  const _BackspaceKey({required this.onTap, required this.onLongPress});

  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Semantics(
      button: true,
      label: 'Delete (hold to clear)',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkResponse(
          onTap: onTap,
          onLongPress: onLongPress,
          containedInkWell: true,
          customBorder: const CircleBorder(),
          highlightColor: Colors.transparent,
          splashColor: z.ink2.withValues(alpha: 0.16),
          child: SizedBox(
            width: AppTokens.minTap,
            height: AppTokens.minTap,
            child: Icon(Icons.backspace_outlined, color: z.ink2, size: 22),
          ),
        ),
      ),
    );
  }
}

/// The full-width green call key: solid fill, ripple only.
class _CallButton extends StatelessWidget {
  const _CallButton({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final enabled = onTap != null;
    final shape = BorderRadius.circular(AppTokens.r14);

    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Call',
      excludeSemantics: true,
      child: AnimatedOpacity(
        duration: AppTokens.fast,
        opacity: enabled ? 1 : 0.45,
        child: Material(
          color: z.callGreen,
          borderRadius: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            borderRadius: shape,
            highlightColor: Colors.transparent,
            splashColor: z.onPrimary.withValues(alpha: 0.16),
            child: SizedBox(
              height: 52,
              width: double.infinity,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.call_rounded, color: z.onPrimary, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Call',
                    style: AppType.bodyStrong.copyWith(
                      color: z.onPrimary,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One keypad key: a sunken rounded rectangle with the digit over its
/// letters.
class _DialKey extends StatelessWidget {
  const _DialKey({
    required this.digit,
    required this.subtext,
    required this.onTap,
    this.onLongPress,
  });

  final String digit;
  final String subtext;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final shape = BorderRadius.circular(AppTokens.r14);
    return Semantics(
      button: true,
      label: digit,
      excludeSemantics: true,
      child: Material(
        color: z.sunken,
        borderRadius: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: shape,
          highlightColor: Colors.transparent,
          splashColor: z.accent.withValues(alpha: 0.16),
          child: SizedBox(
            height: 58,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  digit,
                  style: AppType.tabular(
                    const TextStyle(
                      fontFamily: AppType.family,
                      fontSize: 24,
                      fontWeight: FontWeight.w500,
                      height: 1,
                    ),
                  ).copyWith(color: z.ink),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: 13,
                  child: Text(
                    subtext,
                    style: const TextStyle(
                      fontFamily: AppType.family,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      height: 1.3,
                    ).copyWith(color: z.ink3),
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
