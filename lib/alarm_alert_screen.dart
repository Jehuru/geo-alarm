import 'package:flutter/material.dart';

class AlarmAlertScreen extends StatelessWidget {
  final String alarmName;
  final Future<void> Function() onStop;
  final Future<void> Function() onSnooze;
  final VoidCallback onClose;

  const AlarmAlertScreen({
    super.key,
    required this.alarmName,
    required this.onStop,
    required this.onSnooze,
    required this.onClose,
  });

  Future<void> _stop(BuildContext context) async {
    await onStop();
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _snooze(BuildContext context) async {
    await onSnooze();
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          onClose();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF15152B),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.alarm,
                    size: 100,
                    color: Colors.orangeAccent,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'GEOALARM',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                      letterSpacing: 4,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    alarmName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Your location alarm has been triggered.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  const SizedBox(height: 48),
                  SizedBox(
                    width: double.infinity,
                    height: 58,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => _stop(context),
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text(
                        'STOP ALARM',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                      ),
                      onPressed: () => _snooze(context),
                      icon: const Icon(Icons.snooze),
                      label: const Text('SNOOZE FOR 5 MINUTES'),
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
