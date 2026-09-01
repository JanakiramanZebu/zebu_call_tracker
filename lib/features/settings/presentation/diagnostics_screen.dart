import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_version.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../synchronization/data/sync_service.dart';

/// Everything a support conversation needs and a normal user never should see.
///
/// These figures used to sit in the main Settings list: "Database Health &
/// Diagnostics — SQLite storage integrity, WAL & safe recovery", "Calls Loaded
/// in Memory", "Storage Footprint". They are meaningful to whoever is debugging
/// a handset and meaningless to the person holding it, and mixing them in with
/// the settings people actually change made the whole screen read as an
/// engineering console.
///
/// Reached from one tile at the bottom of Settings. Nothing here is a control;
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
    final feed = ref.watch(callFeedProvider).value;
    final counters = ref.watch(syncCountersProvider).value;
    final nativeSync = ref.watch(nativeSyncStatusProvider).value;

    return Scaffold(
      backgroundColor: AppTokens.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Technical details',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        iconTheme: const IconThemeData(color: AppTokens.textSecondary),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 16),
            child: Text(
              'Information for support. Nothing here needs changing during '
              'normal use.',
              style: TextStyle(
                color: AppTokens.textMuted,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),

          const SectionLabel('This build'),
          const SizedBox(height: 8),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _Row(label: 'App version', value: AppVersion.full),
                const _Divider(),
                _Row(
                  label: 'Server',
                  value: AppConfig.hasServer
                      ? (Uri.tryParse(AppConfig.apiBaseUrl)?.host ?? '—')
                      : 'Not configured',
                ),
                const _Divider(),
                _Row(
                  label: 'Last background run',
                  value: nativeSync?.lastSyncLabel ?? '—',
                ),
                const _Divider(),
                _Row(
                  label: 'Last outcome',
                  value: nativeSync?.status ?? 'Not run yet',
                ),
                if (nativeSync?.error != null) ...[
                  const _Divider(),
                  _Row(label: 'Last error', value: nativeSync!.error!),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),

          const SectionLabel('Call store'),
          const SizedBox(height: 8),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _Row(
                  label: 'Calls held on this phone',
                  value: '${counters?['total'] ?? 0}',
                ),
                const _Divider(),
                _Row(
                  label: 'Sent to server',
                  value: '${counters?['uploaded'] ?? 0}',
                ),
                const _Divider(),
                _Row(
                  label: 'Waiting to send',
                  value: '${counters?['waiting'] ?? 0}',
                ),
                const _Divider(),
                _Row(
                  label: 'Could not be sent',
                  value: '${counters?['failed'] ?? 0}',
                ),
                const _Divider(),
                _Row(
                  label: 'Loaded into the call list',
                  value: '${feed?.entries.length ?? 0}',
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          const SectionLabel('Local storage'),
          const SizedBox(height: 8),
          FutureBuilder<DatabaseHealthReport>(
            future: _health,
            builder: (context, snap) {
              final report = snap.data;
              final checking = snap.connectionState != ConnectionState.done;

              return AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _Row(
                      label: 'Integrity',
                      value: checking
                          ? 'Checking…'
                          : (report?.isHealthy == true ? 'OK' : 'Problem found'),
                      valueColor: checking
                          ? AppTokens.textMuted
                          : (report?.isHealthy == true
                              ? AppTokens.success
                              : AppTokens.danger),
                    ),
                    const _Divider(),
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
                    const _Divider(),
                    _Row(
                      label: 'Rows stored',
                      value: report == null ? '—' : '${report.totalRows}',
                    ),
                    const _Divider(),
                    _Row(
                      label: 'Journal mode',
                      value: report?.journalMode ?? '—',
                    ),
                    if (report?.repaired == true) ...[
                      const _Divider(),
                      _Row(
                        label: 'Repaired',
                        value: '${report!.salvagedRowsCount} rows recovered',
                        valueColor: AppTokens.warning,
                      ),
                    ],
                    if (report?.errorMessage != null) ...[
                      const _Divider(),
                      _Row(label: 'Detail', value: report!.errorMessage!),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => DatabaseHealthSheet(
                onRefreshFeed: () =>
                    ref.read(callFeedProvider.notifier).refresh(),
              ),
            ).then((_) {
              if (mounted) _recheck();
            }),
            icon: const Icon(Icons.healing_rounded, size: 18),
            // The one repair a user can be talked through over the phone. It
            // moved here with the rest of the storage internals rather than
            // being dropped -- it is real recovery, not a readout.
            label: const Text('Check and repair storage'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTokens.brandElectric,
              side: const BorderSide(color: AppTokens.borderDefault),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTokens.r12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: AppTokens.textSecondary,
                  fontSize: 13.5,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: valueColor ?? Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => const Divider(
        height: 1,
        thickness: 1,
        color: AppTokens.borderSubtle,
        indent: 16,
        endIndent: 16,
      );
}

/// Runs the SQLite integrity check and, if needed, the salvage path.
///
/// Lived in Settings until the storage internals moved behind
/// [DiagnosticsScreen]. Public only so that screen can open it.
class DatabaseHealthSheet extends StatefulWidget {
  const DatabaseHealthSheet({super.key, required this.onRefreshFeed});

  final VoidCallback onRefreshFeed;

  @override
  State<DatabaseHealthSheet> createState() => DatabaseHealthSheetState();
}

class DatabaseHealthSheetState extends State<DatabaseHealthSheet> {
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
            ? 'Database repaired successfully! Integrity check: ${updated.integrityCheckResult}'
            : 'Repair finished with warnings. Review report.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      decoration: const BoxDecoration(
        color: AppTokens.surface1,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTokens.r24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTokens.textMuted.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.storage_rounded, color: AppTokens.brandElectric, size: 22),
              const SizedBox(width: 10),
              const Text(
                'Database Health & Diagnostics',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: AppTokens.textSecondary, size: 20),
                onPressed: _loading || _repairing ? null : _loadHealth,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_report != null) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _report!.isHealthy
                    ? AppTokens.success.withValues(alpha: 0.12)
                    : AppTokens.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppTokens.r12),
                border: Border.all(
                  color: _report!.isHealthy ? AppTokens.success : AppTokens.danger,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _report!.isHealthy ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                    color: _report!.isHealthy ? AppTokens.success : AppTokens.danger,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _report!.isHealthy ? 'Database Healthy' : 'Database Needs Attention',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: _report!.isHealthy ? AppTokens.success : AppTokens.danger,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Integrity check: ${_report!.integrityCheckResult}',
                          style: const TextStyle(fontSize: 12.5, color: AppTokens.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTokens.surface2,
                borderRadius: BorderRadius.circular(AppTokens.r12),
                border: Border.all(color: AppTokens.borderSubtle),
              ),
              child: Column(
                children: [
                  _diagRow('Database File', AppDatabase.dbFilename),
                  const Divider(color: AppTokens.borderSubtle, height: 12),
                  _diagRow('Journal Mode', _report!.journalMode.toUpperCase()),
                  const Divider(color: AppTokens.borderSubtle, height: 12),
                  _diagRow('Quick Check', _report!.quickCheckResult),
                  const Divider(color: AppTokens.borderSubtle, height: 12),
                  _diagRow('Foreign Key Check', _report!.foreignKeyCheckResult),
                  const Divider(color: AppTokens.borderSubtle, height: 12),
                  _diagRow('Total Records', '${_report!.totalRows} rows'),
                  const Divider(color: AppTokens.borderSubtle, height: 12),
                  _diagRow('File Size', Fmt.fileSize(_report!.fileSizeBytes)),
                  const Divider(color: AppTokens.borderSubtle, height: 12),
                  _diagRow('Database Path', _report!.dbPath, isLong: true),
                ],
              ),
            ),
            if (_repairMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _repairMessage!,
                style: const TextStyle(color: AppTokens.brandElectric, fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _repairing ? null : _loadHealth,
                    icon: const Icon(Icons.verified_outlined, size: 18),
                    label: const Text('Check Integrity'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: AppTokens.borderDefault),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _repairing ? null : _runRepair,
                    icon: _repairing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.build_rounded, size: 18),
                    label: Text(_repairing ? 'Repairing...' : 'Repair Database'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTokens.brandElectric,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _diagRow(String label, String value, {bool isLong = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: isLong ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppTokens.textMuted, fontSize: 12.5)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
              maxLines: isLong ? 2 : 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
