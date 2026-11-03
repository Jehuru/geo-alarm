import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FeatureCenterScreen extends StatefulWidget {
  final List<Map<String, dynamic>> alarms;
  final List<Map<String, dynamic>> history;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(Map<String, dynamic>) onUseFavorite;
  final Future<void> Function() onClearHistory;

  const FeatureCenterScreen({
    super.key,
    required this.alarms,
    required this.history,
    required this.onToggleFavorite,
    required this.onUseFavorite,
    required this.onClearHistory,
  });

  @override
  State<FeatureCenterScreen> createState() => _FeatureCenterScreenState();
}

class _FeatureCenterScreenState extends State<FeatureCenterScreen> {
  int ringDuration = 30;
  bool vibrationEnabled = true;
  bool checking = false;
  List<Map<String, dynamic>> journeyHistory = [];
  bool locationEnabled = false;
  LocationPermission permission = LocationPermission.denied;
  bool serviceRunning = false;
  String diagnosticsMessage =
      'Run a check to review GPS and background status.';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadJourneyHistory();
  }

  Future<void> _loadJourneyHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('journeyHistory') ?? <String>[];
    final loaded = <Map<String, dynamic>>[];
    for (final item in raw) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is Map) loaded.add(Map<String, dynamic>.from(decoded));
      } catch (_) {}
    }
    if (mounted) setState(() => journeyHistory = loaded);
  }

  Future<void> _clearJourneyHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('journeyHistory');
    if (mounted) setState(() => journeyHistory = []);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      ringDuration = prefs.getInt('alarmRingDurationSeconds') ?? 30;
      vibrationEnabled = prefs.getBool('alarmVibrationEnabled') ?? true;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('alarmRingDurationSeconds', ringDuration);
    await prefs.setBool('alarmVibrationEnabled', vibrationEnabled);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Alarm preferences saved.')));
    }
  }

  Future<void> _runDiagnostics() async {
    setState(() {
      checking = true;
      diagnosticsMessage = 'Checking device permissions…';
    });
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      final currentPermission = await Geolocator.checkPermission();
      final running = await FlutterBackgroundService().isRunning();
      if (!mounted) return;
      setState(() {
        locationEnabled = enabled;
        permission = currentPermission;
        serviceRunning = running;
        checking = false;
        diagnosticsMessage =
            enabled &&
                currentPermission != LocationPermission.denied &&
                currentPermission != LocationPermission.deniedForever
            ? 'GPS is available. Keep GeoAlarm allowed to run in the background and exclude it from battery optimization where your phone supports that.'
            : 'Action required: enable location services and grant GeoAlarm location permission.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        checking = false;
        diagnosticsMessage = 'Some checks could not finish: $error';
      });
    }
  }

  Future<void> _shareJourney() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      final active = widget.alarms
          .where((a) => a['enabled'] != false && a['triggered'] != true)
          .map((a) => a['name']?.toString() ?? 'Saved destination')
          .toList();
      final text = StringBuffer()
        ..writeln('My GeoAlarm journey update')
        ..writeln(
          'Current location: https://maps.google.com/?q=${position.latitude},${position.longitude}',
        )
        ..writeln('Updated: ${DateTime.now()}');
      if (active.isNotEmpty) {
        text.writeln('Active destinations: ${active.join(', ')}');
      }
      await Share.share(text.toString());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not get your location. Check GPS permission and try again.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final favorites = widget.alarms
        .where((a) => a['favorite'] == true)
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('GeoAlarm Feature Center')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.star, color: Colors.amber),
                      SizedBox(width: 8),
                      Text(
                        'Favourite places',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Mark an alarm as a favourite on the homepage to keep its destination here for quick reference.',
                  ),
                  const SizedBox(height: 8),
                  if (favorites.isEmpty)
                    const Text('No favourite destinations yet.')
                  else
                    ...favorites.map(
                      (alarm) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.place),
                        title: Text(alarm['name']?.toString() ?? 'Saved place'),
                        subtitle: Text(
                          '${alarm['latitude'] ?? '—'}, ${alarm['longitude'] ?? '—'}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Create a new alarm for this place',
                              icon: const Icon(Icons.add_alarm),
                              onPressed: () => widget.onUseFavorite(alarm),
                            ),
                            IconButton(
                              tooltip: 'Remove favourite',
                              icon: const Icon(Icons.star, color: Colors.amber),
                              onPressed: () => widget.onToggleFavorite(alarm),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.notifications_active_outlined),
                      SizedBox(width: 8),
                      Text(
                        'Alarm sound & vibration',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Choose how long the in-app alarm sound should play. Android may apply additional notification and battery restrictions.',
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    initialValue: ringDuration,
                    decoration: const InputDecoration(
                      labelText: 'Sound duration',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 30, child: Text('30 seconds')),
                      DropdownMenuItem(value: 60, child: Text('60 seconds')),
                      DropdownMenuItem(value: 90, child: Text('90 seconds')),
                      DropdownMenuItem(value: 120, child: Text('2 minutes')),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => ringDuration = value);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Vibration in alarm notification'),
                    value: vibrationEnabled,
                    onChanged: (value) =>
                        setState(() => vibrationEnabled = value),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _saveSettings,
                      icon: const Icon(Icons.save),
                      label: const Text('SAVE PREFERENCES'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.health_and_safety_outlined),
                      SizedBox(width: 8),
                      Text(
                        'Journey safety',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Share your current location and active destination names through your phone’s share sheet. You choose who receives it.',
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _shareJourney,
                      icon: const Icon(Icons.share_location),
                      label: const Text('SHARE JOURNEY UPDATE'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.settings_suggest_outlined),
                      SizedBox(width: 8),
                      Text(
                        'GPS & background diagnostics',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (checking) const LinearProgressIndicator(),
                  if (!checking && diagnosticsMessage.isNotEmpty)
                    Text(diagnosticsMessage),
                  if (!checking &&
                      diagnosticsMessage !=
                          'Run a check to review GPS and background status.')
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        children: [
                          _diagnosticRow('Location services', locationEnabled),
                          _diagnosticRow(
                            'Location permission',
                            permission != LocationPermission.denied &&
                                permission != LocationPermission.deniedForever,
                          ),
                          _diagnosticRow(
                            'Background service running',
                            serviceRunning,
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: checking ? null : _runDiagnostics,
                      icon: const Icon(Icons.health_and_safety),
                      label: const Text('CHECK DEVICE STATUS'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'For more reliable background alarms, allow background location where requested and set battery usage to unrestricted if your Android device provides that option.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Completed journey history',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Clear journey history',
                        onPressed: journeyHistory.isEmpty
                            ? null
                            : () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (dialogContext) => AlertDialog(
                                    title: const Text('Clear journey history?'),
                                    content: const Text(
                                      'This removes completed and ended journey records from this device.',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(dialogContext, false),
                                        child: const Text('CANCEL'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(dialogContext, true),
                                        child: const Text('CLEAR'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  await _clearJourneyHistory();
                                }
                              },
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                  if (journeyHistory.isEmpty)
                    const Text(
                      'Completed journeys will appear here after you finish or end a monitored journey.',
                    )
                  else
                    ...journeyHistory.take(10).map((journey) {
                      final meters =
                          (journey['travelledDistance'] as num?)?.toDouble() ??
                          0;
                      final seconds =
                          (journey['durationSeconds'] as num?)?.toInt() ?? 0;
                      final distance = meters >= 1000
                          ? '${(meters / 1000).toStringAsFixed(1)} km'
                          : '${meters.round()} m';
                      final duration = seconds < 60
                          ? '$seconds sec'
                          : '${seconds ~/ 60} min';
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          journey['status'] == 'completed'
                              ? Icons.flag_circle
                              : Icons.route,
                          color: journey['status'] == 'completed'
                              ? Colors.green
                              : null,
                        ),
                        title: Text(
                          '${journey['startName'] ?? 'Start'} → ${journey['destinationName'] ?? 'Destination'}',
                        ),
                        subtitle: Text(
                          '$distance travelled • $duration • ${journey['status'] ?? 'ended'}',
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Alarm trigger history'),
              subtitle: Text(
                '${widget.history.length} recorded trigger${widget.history.length == 1 ? '' : 's'}',
              ),
              trailing: IconButton(
                tooltip: 'Clear history',
                icon: const Icon(Icons.delete_outline),
                onPressed: widget.history.isEmpty
                    ? null
                    : () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('Clear alarm history?'),
                            content: const Text(
                              'This removes recorded alarm triggers from this device.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, false),
                                child: const Text('CANCEL'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, true),
                                child: const Text('CLEAR'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true) {
                          final messenger = ScaffoldMessenger.of(context);
                          final navigator = Navigator.of(context);
                          await widget.onClearHistory();
                          if (!mounted) return;
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text('Alarm history cleared.'),
                            ),
                          );
                          navigator.pop();
                        }
                      },
              ),
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('History is available'),
                  content: Text(
                    'GeoAlarm currently has ${widget.history.length} recorded alarm triggers. Open the history icon on the homepage to review records.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('CLOSE'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _diagnosticRow(String label, bool ok) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      ok ? Icons.check_circle : Icons.warning_amber_rounded,
      color: ok ? Colors.green : Colors.orange,
    ),
    title: Text(label),
    trailing: Text(ok ? 'OK' : 'CHECK'),
  );
}
