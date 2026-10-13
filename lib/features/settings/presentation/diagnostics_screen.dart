import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_version.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../synchronization/data/sync_service.dart';

/// Values on this screen are read aloud to support over the phone, so digits
/// are tabular, zeros slashed and letters slightly tracked — the closest IBM
/// Plex Sans gets to a monospace readout without bundling another font.
final TextStyle _readout = AppType.tabular(AppType.small).copyWith(
  fontWeight: FontWeight.w500,
  letterSpacing: 0.2,
  fontFeatures: const [
    FontFeature.tabularFigures(),
    FontFeature.slashedZero(),
  ],
);

/// Everything a support conversation needs and a normal user never should see.
///
/// These figures used to sit in the main Settings list: "Database Health &
/// Diagnostics — SQLite storage integrity, WAL & safe recovery", "Calls Loaded
/// in Memory", "Storage Footprint". They are meaningful to whoever is debugging
/// a handset and meaningless to the person holding it, and mixing them in with
/// the settings people actually change made the whole screen read as an
/// engineering console.
///
/// Support only: reached by long-pressing Version in Settings, never from a
/// visible row. Nothing here is a control;
/// it is all read-only, except the storage check, which is the one repair a
/// user can be talked through over the phone.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  Future<DatabaseHealthReport>? _health;

  @override
  void initState() {
    super.initState();
    _health = AppDatabase.checkHealth();
  }

  void _recheck() => setState(() => _health = AppDatabase.checkHealth());

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final feed = ref.watch(callFeedProvider).value;
    // Moved off Settings with the rest of the read-only figures: the handset
    // model and API level are what a support call asks for, and nothing the
    // person holding the phone can act on.
    final device = ref.watch(deviceInfoProvider).value;
    final counters = ref.watch(syncCountersProvider).value;
    final nativeSync = ref.watch(nativeSyncStatusProvider).value;

    final failedCount = counters?['failed'] ?? 0;
    final waitingCount = counters?['waiting'] ?? 0;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Technical details'),
      ),
      // A pushed screen with no bottom bar: scrollPadding adds the system
      // navigation bar's height so the repair button clears the nav buttons.
      // Rows run edge to edge; each one indents itself by the gutter.
      body: ListView(
        padding: context.scrollPadding(top: 4, bottom: 32, horizontal: 0),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTokens.gutter),
            child: Text(
              'Information for support. Nothing here needs changing during '
              'normal use.',
              style: AppType.small.copyWith(color: z.ink2),
            ),
          ),

          const SectionLabel('This build'),
          ListGroup(
            children: [
              _Row(label: 'App version', value: AppVersion.full),
              _Row(
                label: 'Device',
                value: device == null
                    ? 'Reading…'
                    : '${device["manufacturer"] ?? ""} ${device["model"] ?? ""}'
                          .trim(),
              ),
              _Row(
                label: 'Android',
                value: device == null
                    ? '—'
                    : '${device["osVersion"] ?? "?"} (API ${device["sdkInt"] ?? "?"})',
              ),
              _Row(
                label: 'Server',
                value: AppConfig.hasServer
                    ? (Uri.tryParse(AppConfig.apiBaseUrl)?.host ?? '—')
                    : switch (AppConfig.problem) {
                        ConfigProblem.missingServerUrl =>
                          'No address in this build',
                        ConfigProblem.malformedServerUrl => 'Invalid address',
                        ConfigProblem.insecureServerUrl =>
                          'Insecure (http) address',
                        null => 'Not configured',
                      },
                statusColor: AppConfig.hasServer ? null : z.danger,
              ),
              _Row(
                label: 'Last background run',
                value: switch (nativeSync?.lastSyncAt) {
                  final at? => DateFormat('d MMM, h:mm a').format(at.toLocal()),
                  null => 'Never',
                },
              ),
              _Row(
                label: 'Last outcome',
                // Plain words first; the raw status stays for support.
                value: switch (nativeSync?.status) {
                  final code? => '${nativeSync!.statusLabel} ($code)',
                  null => 'Not run yet',
                },
                statusColor: switch (nativeSync) {
                  null || NativeSyncStatus(status: null) => null,
                  NativeSyncStatus(isHealthy: true) => z.ok,
                  NativeSyncStatus(isBlocked: true) => z.danger,
                  _ => z.warn,
                },
              ),
              if (nativeSync?.error != null)
                _Row(
                  label: 'Last error',
                  value: nativeSync!.error!,
                  valueColor: z.danger,
                ),
            ],
          ),

          const SectionLabel('Call store'),
          ListGroup(
            children: [
              _Row(
                label: 'Calls held on this phone',
                value: '${counters?['total'] ?? 0}',
              ),
              _Row(
                label: 'Sent to server',
                value: '${counters?['uploaded'] ?? 0}',
                valueColor: z.ok,
              ),
              _Row(
                label: 'Waiting to send',
                value: '$waitingCount',
                valueColor: waitingCount > 0 ? z.warn : null,
              ),
              _Row(
                label: 'Could not be sent',
                value: '$failedCount',
                valueColor: failedCount > 0 ? z.danger : null,
              ),
              _Row(
                label: 'Loaded into the call list',
                value: '${feed?.entries.length ?? 0}',
              ),
            ],
          ),

          const SectionLabel('Local storage'),
          FutureBuilder<DatabaseHealthReport>(
            future: _health,
            builder: (context, snap) {
              final report = snap.data;
              final checking = snap.connectionState != ConnectionState.done;

              return ListGroup(
                children: [
                  _Row(
                    label: 'Integrity',
                    value: checking
                        ? 'Checking…'
                        : (report?.isHealthy == true ? 'OK' : 'Problem found'),
                    statusColor: checking
                        ? z.ink3
                        : (report?.isHealthy == true ? z.ok : z.danger),
                  ),
                  _Row(
                    label: 'File size',
                    // The real file, not an estimate. This tile used to
                    // multiply the number of loaded calls by 1280 bytes and
                    // add a constant, which produced a plausible-looking
                    // figure that was never measured from anything.
                    value: report == null
                        ? '—'
                        : Fmt.fileSize(report.fileSizeBytes),
                  ),
                  _Row(
                    label: 'Rows stored',
                    value: report == null ? '—' : '${report.totalRows}',
                  ),
                  _Row(
                    label: 'Journal mode',
                    value: report?.journalMode ?? '—',
                  ),
                  if (report?.repaired == true)
                    _Row(
                      label: 'Repaired',
                      value: '${report!.salvagedRowsCount} rows recovered',
                      statusColor: z.warn,
                    ),
                  if (report?.errorMessage != null)
                    _Row(
                      label: 'Detail',
                      value: report!.errorMessage!,
                      valueColor: z.danger,
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTokens.gutter),
            // The one repair a user can be talked through over the phone. It
            // moved here with the rest of the storage internals rather than
            // being dropped -- it is real recovery, not a readout.
            child: ZButton(
              label: 'Check and repair storage',
              icon: Icons.healing_rounded,
              variant: ZButtonVariant.outline,
              onPressed: () =>
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _DatabaseHealthSheet(
                      onRefreshFeed: () =>
                          ref.read(callFeedProvider.notifier).refresh(),
                    ),
                  ).then((_) {
                    if (mounted) _recheck();
                  }),
            ),
          ),
        ],
      ),
    );
  }
}

/// One label/value line of a [ListGroup]. The value is a right-aligned
/// tabular readout that wraps rather than overflowing — outcomes like
/// "Access removed – contact your admin (BLOCKED)" are long.
///
/// A [statusColor] marks a state (healthy, problem, warning) with a dot and
/// the value in that colour; [valueColor] colours a plain figure.
class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.valueColor,
    this.statusColor,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final text = Text(
      value,
      textAlign: TextAlign.right,
      style: _readout.copyWith(color: statusColor ?? valueColor ?? z.ink2),
    );
    return MergeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.gutter,
            vertical: 14,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(label, style: AppType.small.copyWith(color: z.ink)),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: statusColor == null
                    ? text
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 7),
                            child: StatusDot(color: statusColor!, size: 7),
                          ),
                          const SizedBox(width: 6),
                          Flexible(child: text),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Runs the SQLite integrity check and, if needed, the salvage path.
///
/// Lived in Settings until the storage internals moved behind
/// [DiagnosticsScreen].
///
/// The sheet's shape, colour and drag handle come from the theme; the content
/// scrolls (it can outgrow a short phone) and pads above the system
/// navigation bar.
class _DatabaseHealthSheet extends StatefulWidget {
  const _DatabaseHealthSheet({required this.onRefreshFeed});

  final VoidCallback onRefreshFeed;

  @override
  State<_DatabaseHealthSheet> createState() => _DatabaseHealthSheetState();
}

class _DatabaseHealthSheetState extends State<_DatabaseHealthSheet> {
  DatabaseHealthReport? _report;
  bool _loading = true;
  bool _repairing = false;
  String? _repairMessage;

  @override
  void initState() {
    super.initState();
    _loadHealth();
  }

  Future<void> _loadHealth() async {
    setState(() => _loading = true);
    final report = await AppDatabase.checkHealth();
    if (mounted) {
      setState(() {
        _report = report;
        _loading = false;
      });
    }
  }

  Future<void> _runRepair() async {
    setState(() {
      _repairing = true;
      _repairMessage = null;
    });

    final file = await AppDatabase.getDatabaseFile();
    final success = await AppDatabase.checkAndRepairDatabaseFile(file);
    final updated = await AppDatabase.checkHealth();

    widget.onRefreshFeed();

    if (mounted) {
      setState(() {
        _report = updated;
        _repairing = false;
        _repairMessage = success
            ? 'Storage repaired. Integrity check: ${updated.integrityCheckResult}'
            : 'Repair finished with warnings. See the details above.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    const gutter = EdgeInsets.symmetric(horizontal: AppTokens.gutter);
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: 24 + context.safeBottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppTokens.gutter, 0, 10, 0),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: const Text('Storage check', style: AppType.heading),
                  ),
                ),
                TapIcon(
                  icon: Icons.refresh_rounded,
                  tooltip: 'Check again',
                  size: 20,
                  color: z.ink2,
                  onTap: _loading || _repairing ? null : _loadHealth,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_report != null) ...[
            Padding(
              padding: gutter,
              child: InfoBanner(
                tone: _report!.isHealthy
                    ? BannerTone.success
                    : BannerTone.warning,
                title: _report!.isHealthy
                    ? 'Storage OK'
                    : 'Storage needs repair',
                message: 'Integrity check: ${_report!.integrityCheckResult}',
              ),
            ),
            const SizedBox(height: 16),
            ListGroup(
              children: [
                _Row(label: 'Database file', value: AppDatabase.dbFilename),
                _Row(
                  label: 'Journal mode',
                  value: _report!.journalMode.toUpperCase(),
                ),
                _Row(label: 'Quick check', value: _report!.quickCheckResult),
                _Row(
                  label: 'Foreign key check',
                  value: _report!.foreignKeyCheckResult,
                ),
                _Row(
                  label: 'Total records',
                  value: '${_report!.totalRows} rows',
                ),
                _Row(
                  label: 'File size',
                  value: Fmt.fileSize(_report!.fileSizeBytes),
                ),
                _Row(label: 'Database path', value: _report!.dbPath),
              ],
            ),
            if (_repairMessage != null) ...[
              const SizedBox(height: 12),
              Padding(
                padding: gutter,
                child: Text(
                  _repairMessage!,
                  style: AppType.label.copyWith(color: z.accent),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Padding(
              padding: gutter,
              child: Row(
                children: [
                  Expanded(
                    child: ZButton(
                      label: 'Check again',
                      variant: ZButtonVariant.secondary,
                      onPressed: _repairing ? null : _loadHealth,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ZButton(
                      label: _repairing ? 'Repairing…' : 'Repair storage',
                      loading: _repairing,
                      onPressed: _repairing ? null : _runRepair,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
