import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/user_facing_error.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_client_provider.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/brand.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../call_tracking/data/call_feed.dart' show deviceInfoProvider;
import '../../device/data/device_uuid_store.dart';
import '../data/auth_controller.dart';
import '../data/auth_repository.dart';
import '../domain/session.dart';

/// Device registration per Section 3.1 of the Mobile API Guide.
///
/// Mobile clients authenticate exclusively via [POST /api/v1/mobile/register]
/// using an admin pairing word and employee profile details. Once registered,
/// session tokens are stored in platform-secure storage and the app tracks and
/// synchronizes call activity automatically in the background.
///
/// Laid out as a three-step wizard — setup, about you, work details — rather
/// than one long form: nine fields in a single scroll read as a wall on a
/// phone, and the primary button sat a long way below the fold. Each step
/// validates on "Continue"; the request is still one call at the end.
///
/// Leaving step 1 runs `POST /mobile/lookup` (Mobile login flow §2). A
/// returning employee finds their details already filled in, which is what
/// stops a reinstall from overwriting their profile with whatever they retype.
/// Phone and email are required. They are filled when the lookup sends them
/// in full; when it sends only masked forms, those show in the field as its
/// placeholder and count as filled — the field is sent empty, which the
/// server reads as "keep what you have".
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  static const _stepCount = 3;

  /// One form per step, all kept mounted (see the IndexedStack in build), so
  /// the final submit can re-validate every step and jump to the first one
  /// that is wrong.
  final _stepKeys = List.generate(_stepCount, (_) => GlobalKey<FormState>());

  /// Steps the user has tried to leave at least once. Those validate as the
  /// user types; untouched steps stay quiet instead of opening on red.
  final _attempted = <int>{};

  int _step = 0;
  bool _forward = true;

  /// Drives the step change: a short fade and slide in the travel direction.
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: 1,
  );

  final _pairingWordController = TextEditingController();
  final _employeeCodeController = TextEditingController();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _departmentController = TextEditingController();
  final _designationController = TextEditingController();
  final _locationController = TextEditingController();
  final _managerNameController = TextEditingController();

  final _pairingFocus = FocusNode();
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

  /// The answer for the codes on step 1, or null when there was none — no
  /// lookup yet, or the lookup could not be reached and the user fills the
  /// form in by hand.
  EmployeeLookup? _lookup;

  /// `setup code|employee code` that [_lookup] answered. A lookup runs again
  /// only when this changes.
  String? _lookedUpKey;
  bool _lookingUp = false;

  /// Shown on "About you" when the lookup could not be reached.
  bool _lookupUnavailable = false;

  /// Values the lookup put into fields, so a different code can take them
  /// back out instead of leaving one employee's details under another's code.
  final _autofilled = <TextEditingController, String>{};

  bool get _locked => _busy || _lookingUp;

  @override
  void initState() {
    super.initState();
    // Back here after a sign-out or a revoked session: offer the code this
    // phone used last. The setup code is never stored, so the lookup still
    // waits for the user to enter it.
    LastEmployeeCode.read().then((code) {
      if (!mounted || code == null) return;
      if (_employeeCodeController.text.isEmpty) {
        _employeeCodeController.text = code;
      }
    });
  }

  @override
  void dispose() {
    _enter.dispose();

    _pairingWordController.dispose();
    _employeeCodeController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _departmentController.dispose();
    _designationController.dispose();
    _locationController.dispose();
    _managerNameController.dispose();

    _pairingFocus.dispose();
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

  bool get _isLastStep => _step == _stepCount - 1;

  /// First field of each step, focused when the step opens.
  FocusNode _firstFocusOf(int step) => switch (step) {
    0 => _pairingFocus,
    1 => _nameFocus,
    _ => _departmentFocus,
  };

  void _goTo(int step, {bool focus = true}) {
    if (step == _step) return;
    setState(() {
      _forward = step > _step;
      _step = step;
    });
    _enter.forward(from: 0);
    if (focus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _firstFocusOf(step).requestFocus();
      });
    } else {
      FocusScope.of(context).unfocus();
    }
  }

  bool _validateStep(int step) {
    final ok = _stepKeys[step].currentState?.validate() ?? false;
    if (!ok) setState(() => _attempted.add(step));
    return ok;
  }

  /// "Continue" on steps 1–2, "Set up this phone" on the last.
  Future<void> _next() async {
    if (_locked) return;
    if (!_validateStep(_step)) return;
    if (_isLastStep) {
      await _submit();
      return;
    }
    if (_step == 0 && !await _lookUpEmployee()) return;
    _goTo(_step + 1);
  }

  /// Runs the employee lookup for the codes on step 1 and fills the form from
  /// it. Returns whether the wizard may move on.
  ///
  /// Only a refused setup code, an account that cannot register, or the rate
  /// limit stop the user here. Anything else — no network, a server error, a
  /// server that predates the endpoint — lets them carry on and fill the form
  /// in themselves: the lookup is a convenience, registration still decides.
  Future<bool> _lookUpEmployee() async {
    if (_holdForRateLimit()) return false;
    final pairingWord = _pairingWordController.text.trim().toUpperCase();
    final code = _employeeCodeController.text.trim().toUpperCase();
    final key = '$pairingWord|$code';
    if (key == _lookedUpKey && _lookup != null) {
      if (_lookup!.canRegister) return true;
      setState(() => _failure = _inactiveFailure);
      return false;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _lookingUp = true;
      _failure = null;
    });
    ref.read(sessionRevocationProvider.notifier).acknowledge();

    try {
      final result = await ref
          .read(authControllerProvider.notifier)
          .lookupEmployee(pairingWord: pairingWord, employeeCode: code);
      if (!mounted) return false;
      setState(() {
        _lookedUpKey = key;
        _lookup = result;
        _lookupUnavailable = false;
        _clearAutofill();
        if (!result.canRegister) {
          _failure = _inactiveFailure;
        } else if (result.hasProfile) {
          _fill(result);
        }
      });
      return result.canRegister;
    } on AuthFailure catch (e) {
      if (!mounted) return false;
      final stop = e.kind == AuthFailureKind.invalidCredentials ||
          e.kind == AuthFailureKind.accountDisabled ||
          e.code == 'RATE_LIMIT_EXCEEDED';
      _noteRateLimit(e);
      setState(() {
        if (stop) {
          _failure = e;
        } else {
          _lookedUpKey = null;
          _lookup = null;
          _lookupUnavailable = true;
          _clearAutofill();
        }
      });
      if (e.kind == AuthFailureKind.invalidCredentials) {
        _pairingFocus.requestFocus();
      }
      return !stop;
    } finally {
      if (mounted) setState(() => _lookingUp = false);
    }
  }

  static const _inactiveFailure = AuthFailure(
    AuthFailureKind.accountDisabled,
    'This account is not active. Contact your admin.',
  );

  /// Fills what the server holds. A field it has nothing for stays as the
  /// user left it. Phone and email are filled only when the server sends
  /// them in full; masked values never go into a field, where they would be
  /// sent back and overwrite the real ones.
  void _fill(EmployeeLookup l) {
    void put(TextEditingController c, String? value) {
      if (value == null) return;
      c.text = value;
      _autofilled[c] = value;
    }

    put(_nameController, l.name);
    put(_departmentController, l.department);
    put(_designationController, l.designation);
    put(_locationController, l.location);
    put(_managerNameController, l.managerName);
    _phoneController.clear();
    _emailController.clear();
    put(_emailController, l.email);
    // The field holds the 10 national digits; "+91" is its fixed prefix.
    final digits = l.phone?.replaceAll(RegExp(r'\D'), '');
    put(
      _phoneController,
      digits == null || digits.length < 10
          ? null
          : digits.substring(digits.length - 10),
    );
  }

  /// Takes back lookup values the user has not changed.
  void _clearAutofill() {
    _autofilled.forEach((c, value) {
      if (c.text == value) c.clear();
    });
    _autofilled.clear();
  }

  /// Whether [v] is still exactly what the lookup put into [c]. The server's
  /// own value is accepted as it is, even where it would fail a rule meant
  /// for typing.
  bool _isOnFile(TextEditingController c, String? v) {
    final filled = _autofilled[c];
    return filled != null && v?.trim() == filled;
  }

  /// The step holding a field the server refused, by its API name.
  static int? _stepOfField(String? field) => switch (field) {
    'pairing_word' || 'employee_code' => 0,
    'name' || 'email' || 'phone' => 1,
    'department' || 'designation' || 'location' || 'manager_name' => 2,
    _ => null,
  };

  /// When the server's rate limit lets this phone try again. Each attempt
  /// made before then is refused and only pushes the window further out.
  DateTime? _retryAllowedAt;

  void _noteRateLimit(AuthFailure e) {
    if (e.code != 'RATE_LIMIT_EXCEEDED') return;
    _retryAllowedAt =
        DateTime.now().add(Duration(seconds: e.retryAfterSeconds ?? 60));
  }

  /// True, with the wait on screen, while the rate limit still holds.
  bool _holdForRateLimit() {
    final at = _retryAllowedAt;
    if (at == null) return false;
    final left = at.difference(DateTime.now()).inSeconds;
    if (left <= 0) {
      _retryAllowedAt = null;
      return false;
    }
    setState(() => _failure = AuthFailure(
          AuthFailureKind.server,
          'Too many attempts. Try again in $left seconds.',
          code: 'RATE_LIMIT_EXCEEDED',
          retryAfterSeconds: left,
        ));
    return true;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_holdForRateLimit()) return;

    // Every step was valid when the user left it, but a step is only checked
    // on the way out — re-check all of them so nothing slips through.
    for (var i = 0; i < _stepCount; i++) {
      if (!_validateStep(i)) {
        _goTo(i);
        return;
      }
    }

    setState(() {
      _busy = true;
      _failure = null;
    });
    // The banner has done its job once the user acts on it.
    ref.read(sessionRevocationProvider.notifier).acknowledge();

    try {
      String? androidId;
      try {
        androidId = (await ref.read(deviceInfoProvider.future))['androidId']
            as String?;
      } on Object {
        androidId = null;
      }
      final deviceUuid = await const DeviceUuidStore().getOrCreateUuid(
        preferred: androidId,
      );

      final pairingWord = _pairingWordController.text.trim().toUpperCase();
      final employeeCode = _employeeCodeController.text.trim().toUpperCase();
      final name = _nameController.text.trim();
      final email = _emailController.text.trim();
      final rawPhone = _phoneController.text.trim();
      final department = _departmentController.text.trim();
      final designation = _designationController.text.trim();
      final location = _locationController.text.trim();
      final managerName = _managerNameController.text.trim();

      await ref
          .read(authControllerProvider.notifier)
          .signInWithPairingWord(
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
      _noteRateLimit(e);
      if (mounted) {
        setState(() => _failure = e);
        // Take the user to the step that holds what was refused, with the
        // reason on screen, rather than leave them on a step whose fields are
        // all fine.
        final step = e.kind == AuthFailureKind.invalidCredentials
            ? 0
            : _stepOfField(e.field);
        if (step != null) _goTo(step, focus: false);
      }
    } on Object catch (e) {
      // The exception text goes to the log, not the banner.
      UserFacingError.from(e).log('LOGIN');
      if (mounted) {
        setState(
          () => _failure = const AuthFailure(
            AuthFailureKind.unknown,
            "Couldn't register this phone. Check your connection and try "
            'again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _validatePairingWord(String? v) {
    if (v == null || v.trim().isEmpty) {
      return 'Enter the setup code from your admin';
    }
    if (v.trim().length < 2) return 'The setup code is at least 2 characters';
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
    if (_isOnFile(_nameController, v)) return null;
    final clean = v.trim();
    if (clean.length < 2) return 'Full Name must be at least 2 characters';
    // A name field that accepts "12345" is not validating anything. Allows
    // letters, spaces and the punctuation real names carry — apostrophes,
    // hyphens and the full stop in an initial.
    if (!RegExp(r"^[A-Za-z][A-Za-z .'\-]*$").hasMatch(clean)) {
      return 'Use letters only (spaces, apostrophes and hyphens are allowed)';
    }
    return null;
  }

  String? _validateEmail(String? v) {
    if (v == null || v.trim().isEmpty) {
      // Showing the address on file: sent empty, the server keeps it.
      if (_onFileEmail != null) return null;
      return 'Enter your Email Address';
    }
    if (_isOnFile(_emailController, v)) return null;
    final clean = v.trim();
    // The TLD is deliberately unbounded above 2 characters. The previous
    // pattern capped it at 4, which rejected every address on .online,
    // .finance, .trading and .company — all of them in use here.
    if (!RegExp(r'^[\w.+\-]+@([\w\-]+\.)+[A-Za-z]{2,}$').hasMatch(clean)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  String? _validatePhone(String? v) {
    if (v == null || v.trim().isEmpty) {
      if (_onFilePhone != null) return null;
      return 'Enter your 10-digit Mobile Number';
    }
    if (_isOnFile(_phoneController, v)) return null;
    final digits = v.trim();
    if (digits.length != 10 || !RegExp(r'^[6-9]\d{9}$').hasMatch(digits)) {
      return 'Enter a valid 10-digit mobile number';
    }
    return null;
  }

  String? _validateDepartment(String? v) {
    if (v == null || v.trim().isEmpty) return 'Enter your Department';
    if (_isOnFile(_departmentController, v)) return null;
    if (v.trim().length < 2) return 'Department must be at least 2 characters';
    return null;
  }

  String? _validateDesignation(String? v) {
    if (v == null || v.trim().isEmpty) return 'Enter your Designation / Role';
    if (_isOnFile(_designationController, v)) return null;
    if (v.trim().length < 2) return 'Designation must be at least 2 characters';
    return null;
  }

  String? _validateLocation(String? v) {
    if (v == null || v.trim().isEmpty) {
      return 'Enter your Location / Office Branch';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final revoked = ref.watch(sessionRevocationProvider);
    final configProblem = AppConfig.problem;

    // Messages that explain why the user is here or what went wrong. The
    // config problem blocks setup on every step, so it shows on every step;
    // the sign-out reason is context for starting over, so step 1 only.
    final banners = <Widget>[
      if (configProblem != null) const _ConfigProblemBanner(),
      if (revoked != null && _step == 0) _RevokedBanner(reason: revoked),
      if (_failure != null) _ErrorBanner(failure: _failure!),
    ];

    final pages = [_stepOne(), _stepTwo(), _stepThree()];

    return PopScope(
      // System back walks the wizard backwards before it leaves the app.
      canPop: _step == 0 && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step > 0 && !_busy) _goTo(_step - 1, focus: false);
      },
      child: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Scaffold(
          backgroundColor: context.z.canvas,
          body: BusyOverlay(
            busy: _busy,
            message: 'Setting up this phone…',
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  _WizardHeader(step: _step, total: _stepCount),
                  Expanded(
                    child: AnimatedBuilder(
                      animation: _enter,
                      builder: (context, child) {
                        final t = Curves.easeOutCubic.transform(_enter.value);
                        return Opacity(
                          opacity: t,
                          child: Transform.translate(
                            offset: Offset((1 - t) * (_forward ? 28 : -28), 0),
                            child: child,
                          ),
                        );
                      },
                      // IndexedStack, not a PageView: every step's form stays
                      // mounted, so the final submit can validate them all.
                      child: IndexedStack(
                        index: _step,
                        sizing: StackFit.expand,
                        children: [
                          for (var i = 0; i < _stepCount; i++)
                            Form(
                              key: _stepKeys[i],
                              autovalidateMode: _attempted.contains(i)
                                  ? AutovalidateMode.onUserInteraction
                                  : AutovalidateMode.disabled,
                              child: _StepPage(
                                banners: banners,
                                child: pages[i],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  _WizardFooter(
                    step: _step,
                    isLast: _isLastStep,
                    busy: _locked,
                    // A build with no reachable server cannot register,
                    // however correct the details are. Letting the user fill
                    // in nine fields and press this only to watch it fail is
                    // worse than saying so up front.
                    onNext: _isLastStep && configProblem != null ? null : _next,
                    onBack: () => _goTo(_step - 1, focus: false),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Step 1 · Setup code ───────────────────────────────────────────────────
  Widget _stepOne() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _StepIntro(
        'Set up this phone',
        'Enter the setup code from your admin and your employee code.',
      ),
      const SizedBox(height: 24),
      _Field(
        label: 'Setup code',
        child: TextFormField(
          controller: _pairingWordController,
          focusNode: _pairingFocus,
          enabled: !_locked,
          autocorrect: false,
          enableSuggestions: false,
          textAlign: TextAlign.center,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.next,
          style: AppType.tabular(
            AppType.statement,
          ).copyWith(letterSpacing: 5),
          inputFormatters: [
            UpperCaseFormatter(),
            FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
          ],
          decoration: InputDecoration(
            hintText: 'Enter code',
            hintStyle: AppType.heading.copyWith(
              color: context.z.ink3,
              letterSpacing: 1,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 20,
            ),
            errorMaxLines: 2,
          ),
          validator: _validatePairingWord,
          onFieldSubmitted: (_) => _employeeFocus.requestFocus(),
        ),
      ),
      const SizedBox(height: 18),
      _Field(
        label: 'Employee Code / ID',
        child: TextFormField(
          controller: _employeeCodeController,
          focusNode: _employeeFocus,
          enabled: !_locked,
          autocorrect: false,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.next,
          inputFormatters: [
            UpperCaseFormatter(),
            FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
            LengthLimitingTextInputFormatter(16),
          ],
          decoration: _decoration(hint: 'e.g. ZE770'),
          validator: _validateEmployeeCode,
          onFieldSubmitted: (_) => _next(),
        ),
      ),
    ],
  );

  // ── Step 2 · About you ────────────────────────────────────────────────────
  Widget _stepTwo() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _StepIntro(
        'Tell us about you',
        'Your calls are logged under these details.',
      ),
      const SizedBox(height: 24),
      ..._lookupNotice(),
      _Field(
        label: 'Full Name',
        child: TextFormField(
          controller: _nameController,
          focusNode: _nameFocus,
          enabled: !_locked,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.name],
          decoration: _decoration(),
          validator: _validateFullName,
          onFieldSubmitted: (_) => _emailFocus.requestFocus(),
        ),
      ),
      const SizedBox(height: 18),
      _Field(
        label: 'Email Address',
        child: TextFormField(
          controller: _emailController,
          focusNode: _emailFocus,
          enabled: !_locked,
          autocorrect: false,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.email],
          decoration: _decoration(
            onFile: _onFileEmail,
          ),
          validator: _validateEmail,
          onFieldSubmitted: (_) => _phoneFocus.requestFocus(),
        ),
      ),
      const SizedBox(height: 18),
      _Field(
        label: 'Mobile Phone Number',
        child: TextFormField(
          controller: _phoneController,
          focusNode: _phoneFocus,
          enabled: !_locked,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          keyboardType: TextInputType.phone,
          autofillHints: const [AutofillHints.telephoneNumberNational],
          style: AppType.tabular(AppType.body).copyWith(letterSpacing: 0.6),
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(10),
          ],
          decoration: _decoration(
            onFile: _onFilePhone,
          ).copyWith(
            prefixText: '+91  ',
            prefixStyle: AppType.tabular(
              AppType.bodyStrong,
            ).copyWith(color: context.z.ink3),
          ),
          validator: _validatePhone,
          onFieldSubmitted: (_) => _next(),
        ),
      ),
    ],
  );

  // ── Step 3 · Work details ─────────────────────────────────────────────────
  Widget _stepThree() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _StepIntro(
        'Where you work',
        'Used to group your calls with your team and branch.',
      ),
      const SizedBox(height: 24),
      _Field(
        label: 'Department',
        child: TextFormField(
          controller: _departmentController,
          focusNode: _departmentFocus,
          enabled: !_locked,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          inputFormatters: [UpperCaseFormatter()],
          decoration: _decoration(),
          validator: _validateDepartment,
          onFieldSubmitted: (_) => _designationFocus.requestFocus(),
        ),
      ),
      const SizedBox(height: 18),
      _Field(
        label: 'Designation / Role',
        child: TextFormField(
          controller: _designationController,
          focusNode: _designationFocus,
          enabled: !_locked,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          inputFormatters: [UpperCaseFormatter()],
          decoration: _decoration(),
          validator: _validateDesignation,
          onFieldSubmitted: (_) => _locationFocus.requestFocus(),
        ),
      ),
      const SizedBox(height: 18),
      _Field(
        label: 'Office Location / Branch',
        child: TextFormField(
          controller: _locationController,
          focusNode: _locationFocus,
          enabled: !_locked,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          inputFormatters: [UpperCaseFormatter()],
          decoration: _decoration(),
          validator: _validateLocation,
          onFieldSubmitted: (_) => _managerFocus.requestFocus(),
        ),
      ),
      const SizedBox(height: 18),
      _Field(
        label: 'Reporting Manager Name',
        optional: true,
        child: TextFormField(
          controller: _managerNameController,
          focusNode: _managerFocus,
          enabled: !_locked,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          inputFormatters: [UpperCaseFormatter()],
          decoration: _decoration(),
          onFieldSubmitted: (_) => _next(),
        ),
      ),
    ],
  );

  /// The themed field decoration. The field's name is not inside it: it sits
  /// above the field as a visible label ([_Field]), so a filled form still
  /// says what each field is and the label never shrinks into the border.
  ///
  /// [onFile] is a masked value the server already holds.
  ///
  /// The masked value sits in the field as its placeholder, in full-strength
  /// ink so it reads as filled in. It is never the field's text: a masked
  /// value sent back would overwrite the real one, while an empty field
  /// tells the server to keep what it has. Typing replaces it.
  InputDecoration _decoration({String? hint, String? onFile}) => InputDecoration(
    hintText: onFile ?? hint,
    hintStyle: onFile == null
        ? null
        : AppType.body.copyWith(color: context.z.ink2),
    errorMaxLines: 2,
    helperText: onFile == null ? null : 'On file. Type a new one to change it.',
    helperMaxLines: 2,
  );

  /// The masked email / phone the server holds for this employee, or null.
  String? get _onFileEmail =>
      (_lookup?.hasEmail ?? false) ? _lookup?.emailMasked : null;
  String? get _onFilePhone =>
      (_lookup?.hasPhone ?? false) ? _lookup?.phoneMasked : null;

  /// What the lookup found, above the "About you" fields.
  List<Widget> _lookupNotice() {
    final l = _lookup;
    final Widget? notice;
    if (_lookupUnavailable) {
      notice = const InfoBanner(
        message: "Couldn't check your employee code. Fill in your details "
            'below.',
        tone: BannerTone.warning,
        icon: Icons.cloud_off_rounded,
      );
    } else if (l != null && l.hasProfile) {
      notice = InfoBanner(
        title: 'Welcome back, ${l.name}',
        message: 'We filled in the details on file for ${l.employeeCode}. '
            'Check them before you continue.',
        tone: BannerTone.info,
        icon: Icons.badge_outlined,
      );
    } else if (l != null && !l.exists) {
      notice = InfoBanner(
        title: 'New employee code',
        message: '${l.employeeCode} is not set up yet. Fill in your details '
            'to create your profile.',
        tone: BannerTone.info,
        icon: Icons.person_add_alt_1_outlined,
      );
    } else {
      notice = null;
    }
    return notice == null ? const [] : [notice, const SizedBox(height: 20)];
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

const _stepLabels = ['Setup', 'About you', 'Work details'];

/// Brand row and the three-segment step track.
class _WizardHeader extends StatelessWidget {
  const _WizardHeader({required this.step, required this.total});

  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.gutter,
        14,
        AppTokens.gutter,
        4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const ZebuAppMark(size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Zebu Call Tracker', style: AppType.bodyStrong),
                    Text(
                      'One-time device setup',
                      style: AppType.label.copyWith(
                        color: z.ink3,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Step ${step + 1} of $total',
                style: AppType.tabular(AppType.label).copyWith(color: z.ink3),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Semantics(
            label: 'Step ${step + 1} of $total: ${_stepLabels[step]}',
            excludeSemantics: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < total; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: _TrackSegment(index: i, current: step),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One segment of the step track: a bar and its numbered label.
///
/// Reached segments (done and current) are solid accent; the current one is
/// told apart by its label, and a finished one by the tick before its label.
class _TrackSegment extends StatelessWidget {
  const _TrackSegment({required this.index, required this.current});

  final int index;
  final int current;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final done = index < current;
    final active = index == current;
    final reached = done || active;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedContainer(
          duration: AppTokens.medium,
          curve: AppTokens.ease,
          height: 4,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            color: reached ? z.accent : z.line,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (done) ...[
              Icon(Icons.check_rounded, size: 13, color: z.accent),
              const SizedBox(width: 3),
            ],
            Flexible(
              child: Text(
                '${index + 1} ${_stepLabels[index]}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.captionStrong.copyWith(
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? z.accent : z.ink3,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Scrollable body of one step, with any banners on top.
class _StepPage extends StatelessWidget {
  const _StepPage({required this.banners, required this.child});

  final List<Widget> banners;
  final Widget child;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    // The footer below already sits above the system navigation bar, so this
    // only needs its own breathing room.
    padding: const EdgeInsets.fromLTRB(
      AppTokens.gutter,
      24,
      AppTokens.gutter,
      24,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in banners) ...[b, const SizedBox(height: 16)],
        child,
      ],
    ),
  );
}

/// The step's title and the one line that says what it is for.
class _StepIntro extends StatelessWidget {
  const _StepIntro(this.title, this.subtitle);

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: Text(title, style: AppType.title),
      ),
      const SizedBox(height: 6),
      Text(subtitle, style: AppType.body.copyWith(color: context.z.ink2)),
    ],
  );
}

/// A form field with its name visible above it, and "(optional)" in the muted
/// colour after the name when the field may be left empty.
///
/// The label and the field are merged for screen readers, so the field is
/// still announced by name even though the name is not in its decoration.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.child,
    this.optional = false,
  });

  final String label;
  final bool optional;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: label),
                if (optional)
                  TextSpan(
                    text: ' (optional)',
                    style: TextStyle(
                      color: z.ink3,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
              ],
            ),
            style: AppType.labelStrong.copyWith(color: z.ink2),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Pinned Back / Continue bar, kept above the system navigation bar and —
/// because the Scaffold resizes for it — above the keyboard.
class _WizardFooter extends StatelessWidget {
  const _WizardFooter({
    required this.step,
    required this.isLast,
    required this.busy,
    required this.onNext,
    required this.onBack,
  });

  final int step;
  final bool isLast;
  final bool busy;
  final VoidCallback? onNext;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: z.canvas,
        border: Border(top: BorderSide(color: z.line)),
      ),
      child: BottomSafe(
        minimum: 14,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.gutter,
            14,
            AppTokens.gutter,
            0,
          ),
          child: Row(
            children: [
              AnimatedSize(
                duration: AppTokens.medium,
                curve: AppTokens.ease,
                child: step == 0
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: ZButton(
                          label: 'Back',
                          icon: Icons.arrow_back_rounded,
                          variant: ZButtonVariant.outline,
                          size: ZButtonSize.large,
                          expand: false,
                          onPressed: busy ? null : onBack,
                        ),
                      ),
              ),
              Expanded(
                child: ZButton(
                  label: isLast ? 'Set up this phone' : 'Continue',
                  size: ZButtonSize.large,
                  loading: busy,
                  onPressed: onNext,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.failure});

  final AuthFailure failure;

  @override
  Widget build(BuildContext context) {
    final isFault =
        failure.kind == AuthFailureKind.network ||
        failure.kind == AuthFailureKind.server;

    return InfoBanner(
      message: failure.message,
      tone: isFault ? BannerTone.warning : BannerTone.danger,
      icon: isFault ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
    );
  }
}

/// Explains a sign-out the user did not ask for.
class _RevokedBanner extends StatelessWidget {
  const _RevokedBanner({required this.reason});

  final SessionRevokedReason reason;

  @override
  Widget build(BuildContext context) {
    final message = switch (reason) {
      SessionRevokedReason.invalidToken =>
        'You were signed out. Set up this phone again to keep sending '
            'your calls.',
      SessionRevokedReason.noSession =>
        'This phone is no longer set up. Enter your details again to '
            'reconnect it.',
    };

    return InfoBanner(
      message: message,
      tone: BannerTone.warning,
      icon: Icons.lock_reset_rounded,
    );
  }
}

/// Says plainly that the app itself was built wrong.
///
/// This is not a user error and there is no user action that fixes it, so it
/// names the one thing that helps: get a correctly built app. Previously such a
/// build looked completely normal until the first request failed.
class _ConfigProblemBanner extends StatelessWidget {
  const _ConfigProblemBanner();

  @override
  Widget build(BuildContext context) {
    final message = AppConfig.problemMessage;
    if (message == null) return const SizedBox.shrink();

    return InfoBanner(
      title: "This app can't connect",
      message: message,
      tone: BannerTone.danger,
      icon: Icons.report_gmailerrorred_rounded,
    );
  }
}
