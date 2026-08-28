import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../shared/widgets/brand.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../data/auth_controller.dart';
import '../domain/session.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordFocus = FocusNode();

  bool _busy = false;
  bool _obscure = true;
  AuthFailure? _failure;

  @override
  void dispose() {
    _idController.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Dismissing the keyboard first means the error banner is not hidden behind
    // it when the attempt fails.
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _failure = null;
    });

    try {
      await ref
          .read(authControllerProvider.notifier)
          .signIn(
            employeeId: _idController.text.trim(),
            password: _passwordController.text,
          );
      // No navigation here: the root gate watches the session and swaps the
      // screen itself, so there is exactly one place that decides what is on
      // screen after sign-in.
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _failure = e);
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _failure = AuthFailure(AuthFailureKind.unknown, '$e'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.surface,
      body: SafeArea(
        child: BusyOverlay(
          busy: _busy,
          message: 'Signing in…',
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              // Fill the viewport so the footer can sit at the bottom on a tall
              // phone, while still scrolling when the keyboard takes half the
              // screen on a short one.
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: ZebuLockup(),
                      ),
                      const SizedBox(height: 48),
                      Text(
                        'Sign in',
                        style: context.text.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.6,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Use the employee account issued by your administrator.',
                        style: context.text.bodyMedium?.copyWith(
                          color: context.palette.muted,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (_failure != null) ...[
                        _ErrorBanner(failure: _failure!),
                        const SizedBox(height: 16),
                      ],
                      Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const _FieldLabel('Employee ID'),
                            TextFormField(
                              controller: _idController,
                              enabled: !_busy,
                              autocorrect: false,
                              textCapitalization: TextCapitalization.characters,
                              textInputAction: TextInputAction.next,
                              keyboardType: TextInputType.visiblePassword,
                              inputFormatters: [
                                UpperCaseFormatter(),
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[A-Za-z0-9\-]'),
                                ),
                                LengthLimitingTextInputFormatter(16),
                              ],
                              decoration: const InputDecoration(
                                hintText: 'EMP-4471',
                                prefixIcon: Icon(
                                  Icons.badge_outlined,
                                  size: 20,
                                ),
                              ),
                              validator: (v) =>
                                  (v == null || v.trim().isEmpty)
                                  ? 'Enter your employee ID'
                                  : null,
                              onFieldSubmitted: (_) =>
                                  _passwordFocus.requestFocus(),
                            ),
                            const SizedBox(height: 16),
                            const _FieldLabel('Password'),
                            TextFormField(
                              controller: _passwordController,
                              focusNode: _passwordFocus,
                              enabled: !_busy,
                              obscureText: _obscure,
                              autocorrect: false,
                              enableSuggestions: false,
                              textInputAction: TextInputAction.done,
                              decoration: InputDecoration(
                                hintText: '••••••••••',
                                prefixIcon: const Icon(
                                  Icons.lock_outline_rounded,
                                  size: 20,
                                ),
                                suffixIcon: IconButton(
                                  onPressed: () =>
                                      setState(() => _obscure = !_obscure),
                                  icon: Icon(
                                    _obscure
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    size: 20,
                                    color: context.palette.muted,
                                  ),
                                  tooltip: _obscure
                                      ? 'Show password'
                                      : 'Hide password',
                                ),
                              ),
                              validator: (v) => (v == null || v.isEmpty)
                                  ? 'Enter your password'
                                  : null,
                              onFieldSubmitted: (_) => _submit(),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _busy ? null : () => _showForgotSheet(context),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 36),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Forgot password?'),
                        ),
                      ),
                      const SizedBox(height: 18),
                      LoadingFilledButton(
                        label: 'Sign in',
                        loading: _busy,
                        onPressed: _submit,
                      ),
                      const SizedBox(height: 20),
                      const _DeviceNotice(),
                      const Spacer(),
                      const SizedBox(height: 20),
                      Center(
                        child: Text(
                          AppConfig.buildLabel,
                          style: context.text.bodySmall?.copyWith(
                            color: context.palette.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showForgotSheet(BuildContext context) {
    // A self-service reset would need an endpoint that does not exist; telling
    // the user exactly who to ask is more useful than a dead link.
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: context.colors.surface,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconChip(
              icon: Icons.key_outlined,
              color: context.colors.primary,
              size: 44,
              iconSize: 22,
            ),
            const SizedBox(height: 16),
            Text(
              'Password resets go through your administrator',
              style: context.text.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Employee accounts are issued and reset centrally. Ask your '
              'reporting manager or the IT helpdesk to reset it — the app '
              'cannot do it from this device.',
              style: context.text.bodyMedium?.copyWith(
                color: context.palette.muted,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Got it'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Employee IDs are issued uppercase; forcing the case as the user types avoids
/// a "correct password, wrong case" failure that reads as a server bug.
class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => TextEditingValue(
    text: newValue.text.toUpperCase(),
    selection: newValue.selection,
    composing: TextRange.empty,
  );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: context.text.bodySmall?.copyWith(
        fontWeight: FontWeight.w600,
        fontSize: 13,
      ),
    ),
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.failure});

  final AuthFailure failure;

  @override
  Widget build(BuildContext context) {
    // A network failure is not the user's mistake, so it is not shown in the
    // same red as a rejected credential.
    final isFault = failure.kind == AuthFailureKind.network ||
        failure.kind == AuthFailureKind.server;
    final color = isFault ? context.palette.waiting : context.palette.missed;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isFault
                ? Icons.wifi_off_rounded
                : Icons.error_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              failure.message,
              style: context.text.bodySmall?.copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceNotice extends StatelessWidget {
  const _DeviceNotice();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: context.palette.tint,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 18,
          color: context.palette.muted,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Signing in registers this device to your account. Calls made on '
            'it are recorded against your employee record.',
            style: context.text.bodySmall?.copyWith(
              color: context.palette.muted,
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );
}
