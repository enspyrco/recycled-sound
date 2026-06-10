// Excluded from coverage: post-capture screen depending on live scanner flow + cloud upload
// coverage:ignore-file
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/firebase_providers.dart';
import '../../../core/services/device_telemetry.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/diagnostic_readout.dart';
import '../../../core/widgets/thermal_gauge.dart';
import '../providers/scanner_providers.dart';

/// Analysing screen (Screen 1C) — animated progress during real scan pipeline.
///
/// Calls the hybrid scanner pipeline (upload → CLIP + Vision → search → fusion)
/// and maps real progress to the step indicators. On completion, sets the result
/// in the provider and navigates to the results screen.
class AnalysingScreen extends ConsumerStatefulWidget {
  const AnalysingScreen({super.key, required this.imagePath});

  final String imagePath;

  @override
  ConsumerState<AnalysingScreen> createState() => _AnalysingScreenState();
}

class _AnalysingScreenState extends ConsumerState<AnalysingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  int _stepIndex = 0;
  String? _error;

  final _telemetryService = DeviceTelemetryService();
  DeviceTelemetry? _telemetry;
  Timer? _thermalTicker;

  static const _steps = [
    'Uploading image…',
    'Detecting hearing aid…',
    'Identifying brand & model…',
    'Matching specifications…',
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _startScan();
    _refreshTelemetry();
    // Re-poll thermal/battery every 2s while the loading screen is visible.
    _thermalTicker = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshTelemetry(),
    );
  }

  Future<void> _refreshTelemetry() async {
    try {
      final t = await _telemetryService.snapshot();
      if (!mounted) return;
      setState(() => _telemetry = t);
    } catch (_) {
      // Telemetry is decorative — never block the scan on it.
    }
  }

  Future<void> _startScan() async {
    try {
      final repository = ref.read(scannerRepositoryProvider);
      final result = await repository.analyzeImage(
        widget.imagePath,
        onProgress: (status) {
          if (!mounted) return;
          // Map progress messages to step indices
          final step = switch (status) {
            _ when status.contains('Loading') => 0,
            _ when status.contains('Uploading') => 0,
            _ when status.contains('Identifying') || status.contains('Detecting') => 1,
            _ when status.contains('brand') => 2,
            _ when status.contains('Matching') || status.contains('specifications') => 3,
            _ => _stepIndex,
          };
          setState(() => _stepIndex = step);
        },
      );

      if (!mounted) return;

      // Complete all steps visually
      setState(() => _stepIndex = _steps.length - 1);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      if (!mounted) return;

      // Set the real result in the provider
      ref.read(scanResultProvider.notifier).setResult(result);
      context.pushReplacement('/scan/confirm');
    } catch (e) {
      if (!mounted) return;
      // Stop the telemetry ticker once we're in error state — the screen is
      // quiescent post-error and there's no reason to keep polling.
      _thermalTicker?.cancel();
      _thermalTicker = null;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _retry() async {
    setState(() {
      _error = null;
      _stepIndex = 0;
    });
    _thermalTicker ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshTelemetry(),
    );
    _startScan();
  }

  @override
  void dispose() {
    _thermalTicker?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: _error != null ? _buildError() : _buildProgress(),
          ),
        ),
      ),
    );
  }

  Widget _buildProgress() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Rotating scan icon
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => Transform.rotate(
            angle: _controller.value * 6.28,
            child: child,
          ),
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.center_focus_strong,
              size: 40,
              color: AppColors.primary,
            ),
          ),
        ),
        const SizedBox(height: 32),
        Text('Analysing…', style: AppTypography.h2),
        const SizedBox(height: 24),

        // Diagnostic readout (auto-cycling device facts) + thermal gauge.
        if (_telemetry != null) ...[
          DiagnosticReadout(entries: _telemetry!.asReadout()),
          const SizedBox(height: 16),
          ThermalGauge(
            load: _telemetry!.thermalLoad,
            label: 'THERMAL LOAD',
            subLabel:
                '${_telemetry!.thermalState.label} · ${_telemetry!.thermalState.estimatedCelsiusBand}',
            coolDownNeeded: _telemetry!.thermalState.coolDownNeeded,
          ),
          const SizedBox(height: 24),
        ],

        // Step indicators
        ...List.generate(_steps.length, (i) {
          final isComplete = i < _stepIndex;
          final isCurrent = i == _stepIndex;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  isComplete
                      ? Icons.check_circle
                      : isCurrent
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                  size: 20,
                  color: isComplete || isCurrent
                      ? AppColors.primary
                      : AppColors.border,
                ),
                const SizedBox(width: 12),
                Text(
                  _steps[i],
                  style: AppTypography.body.copyWith(
                    color: isComplete || isCurrent
                        ? AppColors.text
                        : AppColors.textMuted,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: AppColors.error.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(
            Icons.error_outline,
            size: 40,
            color: AppColors.error,
          ),
        ),
        const SizedBox(height: 32),
        Text('Scan Failed', style: AppTypography.h2),
        const SizedBox(height: 12),
        Text(
          _error!,
          style: AppTypography.body.copyWith(color: AppColors.textMuted),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _retry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try Again'),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => context.pop(),
          child: const Text('Back to Camera'),
        ),
      ],
    );
  }
}
