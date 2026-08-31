import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/brand.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../device/data/device_uuid_store.dart';
import '../data/auth_controller.dart';
import '../domain/session.dart';

/// Single-step Device Registration Screen per Section 3.1 of Mobile API Guide.
///
/// Mobile clients authenticate exclusively via [POST /api/v1/mobile/register]
/// using an admin pairing word and employee profile details. Once registered,
/// session tokens are stored in platform-secure storage and the app tracks and
/// synchronizes call activity automatically in the background.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();

  final _pairingWordController = TextEditingController();
  final _employeeCodeController = TextEditingController();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _departmentController = TextEditingController();
  final _designationController = TextEditingController();
  final _locationController = TextEditingController();
  final _managerNameController = TextEditingController();

  final _employeeFocus = FocusNode();
  final _nameFocus = FocusNode();
  final _emailFocus = FocusNode();
  final _phoneFocus = FocusNode();
  final _departmentFocus = FocusNode();
  final _designationFocus = FocusNode();
  final _locationFocus = FocusNode();
  final _managerFocus = FocusNode();

  bool _busy = false;
  AuthFailure? _failure;

  @override
  void dispose() {
    _pairingWordController.dispose();
    _employeeCodeController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _departmentController.dispose();
    _designationController.dispose();
    _locationController.dispose();
    _managerNameController.dispose();

    _employeeFocus.dispose();
    _nameFocus.dispose();
    _emailFocus.dispose();
    _phoneFocus.dispose();
    _departmentFocus.dispose();
    _designationFocus.dispose();
    _locationFocus.dispose();
    _managerFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _failure = null;
    });

    try {
      final deviceUuid = await const DeviceUuidStore().getOrCreateUuid();

      final pairingWord = _pairingWordController.text.trim().toUpperCase();
      final employeeCode = _employeeCodeController.text.trim().toUpperCase();
      final name = _nameController.text.trim();
      final email = _emailController.text.trim();
      final rawPhone = _phoneController.text.trim();
      final department = _departmentController.text.trim();
      final designation = _designationController.text.trim();
      final location = _locationController.text.trim();
      final managerName = _managerNameController.text.trim();

      await ref.read(authControllerProvider.notifier).signInWithPairingWord(
            pairingWord: pairingWord,
            employeeCode: employeeCode,
            name: name,
            email: email.isEmpty ? null : email,
            phone: rawPhone,
            department: department,
            designation: designation,
            location: location,
            managerName: managerName.isEmpty ? null : managerName,
            mobileUniqueId: deviceUuid,
          );
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _failure = e);
    } on Object catch (e) {
      if (mounted) {
        setState(() => _failure = AuthFailure(AuthFailureKind.unknown, '$e'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _validatePairingWord(String? v) {
    if (v == null || v.trim().isEmpty) return 'Enter the Pairing Word';
    if (v.trim().length < 2) return 'Pairing Word must be at least 2 characters';
    return null;
  }

  String? _validateEmployeeCode(String? v) {
    if (v == null || v.trim().isEmpty) return 'Enter your Employee Code';
    final raw = v.trim().toUpperCase();
    final pattern = RegExp(r'^[A-Z0-9]{2,16}$');
    if (!pattern.hasMatch(raw)) {
      return 'Enter a valid Employee Code (e.g. ZE770 or EMP0042)';
    }
    return null;
  }

  String? _validateFullName(String? v) {
    if (v == null || v.trim().isEmpty) return 'Enter your Full Name';
    if (v.trim().length < 2) return 'Full Name must be at least 2 characters';
    return null;
  }

  String? _validateEmail(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    final clean = v.trim();
    if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(clean)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  String? _validatePhone(String? v) {
    if (v == null || v.trim().isEmpty) return 'Enter your 10-digit Mobile Number';
    final digits = v.trim();
    if (digits.length != 10 || !RegExp(r'^[6-9]\d{9}$').hasMatch(digits)) {
      return 'Enter a valid 10-digit mobile number';
    }
    return null;
  }

  String? _validateDepartment(String? v) {
    if (v == null || v.trim().isEmpty) return 'Enter your Department';
    if (v.trim().length < 2) return 'Department must be at least 2 characters';
    return null;
  }

  String? _validateDesignation(String? v) {
    if (v == null || v.trim().isEmpty) return 'Enter your Designation / Role';
    if (v.trim().length < 2) return 'Designation must be at least 2 characters';
    return null;
  }

  String? _validateLocation(String? v) {
    if (v == null || v.trim().isEmpty) return 'Enter your Location / Office Branch';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        backgroundColor: isDark ? AppColors.bgDark : const Color(0xFFF4F6F9),
        body: SafeArea(
          child: BusyOverlay(
            busy: _busy,
            message: 'Registering device with server…',
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Top App Icon Brand Hero Header
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 24,
                      horizontal: 20,
                    ),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFF0044DB),
                          AppColors.brand,
                          Color(0xFF00237D),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.brand.withValues(alpha: 0.30),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        // Official App Icon Tile
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.25),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: const ZebuAppMark(size: 56),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Zebu Call Tracker',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.4,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'One-Time Device Setup',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Main Registration Form Card Container
                  Card(
                    elevation: 0,
                    color: isDark ? AppColors.surfaceDark : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(
                        color: isDark
                            ? AppColors.outlineDark
                            : AppColors.outlineLight,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.app_registration_rounded,
                                size: 22,
                                color: context.colors.primary,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                'Device Pairing & Setup',
                                style: context.text.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 17,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Enter the admin pairing word and your employee details to activate background call tracking.',
                            style: context.text.bodySmall?.copyWith(
                              color: context.palette.muted,
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 20),

                          if (_failure != null) ...[
                            _ErrorBanner(failure: _failure!),
                            const SizedBox(height: 16),
                          ],

                          Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const _FieldLabel('Pairing Word'),
                                TextFormField(
                                  controller: _pairingWordController,
                                  enabled: !_busy,
                                  autocorrect: false,
                                  textCapitalization:
                                      TextCapitalization.characters,
                                  textInputAction: TextInputAction.next,
                                  inputFormatters: [
                                    UpperCaseFormatter(),
                                    FilteringTextInputFormatter.allow(
                                      RegExp(r'[A-Za-z0-9]'),
                                    ),
                                  ],
                                  decoration: _buildInputDecoration(
                                    context,
                                    hint: '',
                                    prefixIcon: Icons.vpn_key_outlined,
                                  ),
                                  validator: _validatePairingWord,
                                  onFieldSubmitted: (_) =>
                                      _employeeFocus.requestFocus(),
                                ),
                                const SizedBox(height: 14),

                                const _FieldLabel('Employee Code / ID'),
                                TextFormField(
                                  controller: _employeeCodeController,
                                  focusNode: _employeeFocus,
                                  enabled: !_busy,
                                  autocorrect: false,
                                  textCapitalization:
                                      TextCapitalization.characters,
                                  textInputAction: TextInputAction.next,
                                  inputFormatters: [
                                    UpperCaseFormatter(),
                                    FilteringTextInputFormatter.allow(
                                      RegExp(r'[A-Za-z0-9]'),
                                    ),
                                    LengthLimitingTextInputFormatter(16),
                                  ],
                                  decoration: _buildInputDecoration(
                                    context,
                                    hint: '',
                                    prefixIcon: Icons.badge_outlined,
                                  ),
                                  validator: _validateEmployeeCode,
                                  onFieldSubmitted: (_) =>
                                      _nameFocus.requestFocus(),
                                ),
                                const SizedBox(height: 14),

                                const _FieldLabel('Full Name'),
                                TextFormField(
                                  controller: _nameController,
                                  focusNode: _nameFocus,
                                  enabled: !_busy,
                                  textCapitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.next,
                                  decoration: _buildInputDecoration(
                                    context,
                                    hint: '',
                                    prefixIcon: Icons.person_outline_rounded,
                                  ),
                                  validator: _validateFullName,
                                  onFieldSubmitted: (_) =>
                                      _emailFocus.requestFocus(),
                                ),
                                const SizedBox(height: 14),
      
                                const _FieldLabel('Email Address'),
                                TextFormField(
                                  controller: _emailController,
                                  focusNode: _emailFocus,
                                  enabled: !_busy,
                                  autocorrect: false,
                                  keyboardType: TextInputType.emailAddress,
                                  textInputAction: TextInputAction.next,
                                  decoration: _buildInputDecoration(
                                    context,
                                    hint: '',
                                    prefixIcon: Icons.email_outlined,
                                  ),
                                  validator: _validateEmail,
                                  onFieldSubmitted: (_) =>
                                      _phoneFocus.requestFocus(),
                                ),
                                const SizedBox(height: 14),

                                const _FieldLabel('Mobile Phone Number'),
                                TextFormField(
                                  controller: _phoneController,
                                  focusNode: _phoneFocus,
                                  enabled: !_busy,
                                  autocorrect: false,
                                  textInputAction: TextInputAction.next,
                                  keyboardType: TextInputType.phone,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                    LengthLimitingTextInputFormatter(10),
                                  ],
                                  decoration: _buildInputDecoration(
                                    context,
                                    hint: '',
                                    prefixIcon: Icons.phone_android_rounded,
                                  ),
                                  validator: _validatePhone,
                                  onFieldSubmitted: (_) =>
                                      _departmentFocus.requestFocus(),
                                ),
                                const SizedBox(height: 14),

                                const _FieldLabel('Department'),
                                TextFormField(
                                  controller: _departmentController,
                                  focusNode: _departmentFocus,
                                  enabled: !_busy,
                                  textCapitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.next,
                                  inputFormatters: [UpperCaseFormatter()],
                                  decoration: _buildInputDecoration(
                                    context,
                                    hint: '',
                                    prefixIcon: Icons.business_outlined,
                                  ),
                                  validator: _validateDepartment,
                                  onFieldSubmitted: (_) =>
                                      _designationFocus.requestFocus(),
                                ),
                                const SizedBox(height: 14),

                                const _FieldLabel('Designation / Role'),
                                TextFormField(
                                  controller: _designationController,
                                  focusNode: _designationFocus,
                                  enabled: !_busy,
                                  textCapitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.next,
                                  inputFormatters: [UpperCaseFormatter()],
                                  decoration: _buildInputDecoration(
                                    context,
                                    hint: '',
                                    prefixIcon: Icons.work_outline_rounded,
                                  ),
                                  validator: _validateDesignation,
                                  onFieldSubmitted: (_) =>
                                      _locationFocus.requestFocus(),
                                ),
                                const SizedBox(height: 14),

                                const _FieldLabel('Office Location / Branch'),
                                TextFormField(
                                  controller: _locationController,
                                  focusNode: _locationFocus,
                                  enabled: !_busy,
                                  textCapitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.next,
                                  inputFormatters: [UpperCaseFormatter()],
                                  decoration: _buildInputDecoration(
                                    context,
                                    hint: '',
                                    prefixIcon: Icons.location_on_outlined,
                                  ),
                                  validator: _validateLocation,
                                  onFieldSubmitted: (_) =>
                                      _managerFocus.requestFocus(),
                                ),
                                const SizedBox(height: 14),
      
                                const _FieldLabel('Reporting Manager Name'),
                                TextFormField(
                                  controller: _managerNameController,
                                  focusNode: _managerFocus,
                                  enabled: !_busy,
                                  textCapitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.done,
                                  inputFormatters: [UpperCaseFormatter()],
                                  decoration: _buildInputDecoration(
                                    context,
                                    hint: '',
                                    prefixIcon:
                                        Icons.supervisor_account_outlined,
                                  ),
                                  onFieldSubmitted: (_) => _submit(),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),

                          LoadingFilledButton(
                            label: 'Register & Activate Device',
                            loading: _busy,
                            onPressed: _submit,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  const _DeviceNotice(),
                  const SizedBox(height: 20),

                  Center(
                    child: Text(
                      AppConfig.buildLabel,
                      style: context.text.bodySmall?.copyWith(
                        color: context.palette.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _buildInputDecoration(
    BuildContext context, {
    required String hint,
    required IconData prefixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: context.text.bodyMedium?.copyWith(
        color: context.palette.muted.withValues(alpha: 0.55),
        fontSize: 14,
      ),
      filled: true,
      fillColor: context.palette.field,
      prefixIcon: Icon(
        prefixIcon,
        size: 19,
        color: context.colors.primary,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: context.colors.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: context.colors.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: context.colors.primary, width: 1.8),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: context.palette.missed),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: context.palette.missed, width: 1.8),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 14,
      ),
    );
  }
}

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
    final isFault =
        failure.kind == AuthFailureKind.network ||
        failure.kind == AuthFailureKind.server;
    final color = isFault ? context.palette.waiting : context.palette.missed;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isFault ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
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
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.colors.outlineVariant),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.shield_outlined,
          size: 18,
          color: context.colors.primary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'One-time device registration. Once registered, this handset automatically tracks and synchronizes call activities in the background.',
            style: context.text.bodySmall?.copyWith(
              color: context.palette.muted,
              height: 1.5,
              fontSize: 12,
            ),
          ),
        ),
      ],
    ),
  );
}
