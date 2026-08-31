import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../call_tracking/data/call_feed.dart';

/// Modern dark dial pad bottom sheet matching Samsung phone app feel.
class DialPadSheet extends ConsumerStatefulWidget {
  const DialPadSheet({super.key, this.initialNumber});

  final String? initialNumber;

  static Future<void> show(BuildContext context, {String? initialNumber}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
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

  String? _findContactName(String number) {
    if (number.length < 3) return null;
    final entries = ref.read(callFeedProvider).value?.entries ?? const [];
    for (final entry in entries) {
      final raw = entry.row.number?.replaceAll(RegExp(r'[^0-9]'), '') ?? '';
      final query = number.replaceAll(RegExp(r'[^0-9]'), '');
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
    final matchedName = _findContactName(_digits);

    return Container(
      decoration: const BoxDecoration(
        color: AppTokens.surface1,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTokens.r24)),
        border: Border(
          top: BorderSide(color: AppTokens.borderDefault, width: 1),
          left: BorderSide(color: AppTokens.borderDefault, width: 1),
          right: BorderSide(color: AppTokens.borderDefault, width: 1),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        12,
        24,
        MediaQuery.of(context).padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTokens.textMuted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Contact name suggestion if matched
          SizedBox(
            height: 20,
            child: matchedName != null
                ? Text(
                    matchedName,
                    style: const TextStyle(
                      color: AppTokens.brandElectric,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : null,
          ),
          const SizedBox(height: 6),

          // Number display & Backspace row
          Container(
            height: 52,
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(width: 44), // balance backspace button
                Expanded(
                  child: Text(
                    _digits.isEmpty
                        ? 'Enter number'
                        : Fmt.prettyNumber(_digits),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: _digits.length > 12 ? 22 : 28,
                      fontWeight: FontWeight.w700,
                      color: _digits.isEmpty
                          ? AppTokens.textMuted.withValues(alpha: 0.6)
                          : Colors.white,
                      letterSpacing: 1.2,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: _digits.isNotEmpty
                      ? GestureDetector(
                          onLongPress: _clear,
                          child: IconButton(
                            icon: const Icon(
                              Icons.backspace_outlined,
                              color: AppTokens.textSecondary,
                              size: 22,
                            ),
                            onPressed: _backspace,
                            tooltip: 'Delete (hold to clear)',
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // 3x4 Dialpad Grid
          _buildKeypadRow('1', '', '2', 'ABC', '3', 'DEF'),
          const SizedBox(height: 14),
          _buildKeypadRow('4', 'GHI', '5', 'JKL', '6', 'MNO'),
          const SizedBox(height: 14),
          _buildKeypadRow('7', 'PQRS', '8', 'TUV', '9', 'WXYZ'),
          const SizedBox(height: 14),
          _buildKeypadRow('*', '', '0', '+', '#', '', isZeroSpecial: true),
          const SizedBox(height: 22),

          // Action Call Button
          Center(
            child: Material(
              color: AppTokens.callIncoming,
              shape: const CircleBorder(),
              elevation: 4,
              shadowColor: AppTokens.callIncoming.withValues(alpha: 0.4),
              child: InkWell(
                onTap: _digits.isNotEmpty ? _call : null,
                customBorder: const CircleBorder(),
                child: Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppTokens.callIncoming.withValues(alpha: 0.35),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.phone_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            ),
          ),
        ],
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
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _DialKey(
          digit: d1,
          subtext: s1,
          onTap: () => _append(d1),
        ),
        _DialKey(
          digit: d2,
          subtext: s2,
          onTap: () => _append(d2),
          onLongPress: isZeroSpecial ? () => _append('+') : null,
        ),
        _DialKey(
          digit: d3,
          subtext: s3,
          onTap: () => _append(d3),
        ),
      ],
    );
  }
}

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
    return Material(
      color: AppTokens.surface2,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        customBorder: const CircleBorder(),
        splashColor: AppTokens.brandElectric.withValues(alpha: 0.3),
        highlightColor: AppTokens.brandElectric.withValues(alpha: 0.15),
        child: Container(
          width: 66,
          height: 66,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppTokens.borderSubtle, width: 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                digit,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.1,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (subtext.isNotEmpty)
                Text(
                  subtext,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: AppTokens.textMuted,
                    letterSpacing: 1.1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
