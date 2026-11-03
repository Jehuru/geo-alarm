import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'add_alarm_screen.dart';

const String alarmsKey = 'activeAlarms';
const String triggerKey = 'backgroundAlarmTrigger';
const String serviceChannelId = 'geoalarm_service';
const String alarmChannelId = 'geoalarm_alarm_channel';

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

final AudioPlayer audioPlayer = AudioPlayer();

String alarmIdentifier(Map alarm) {
  return '${alarm['name']}|${alarm['location']}';
}

@pragma('vm:entry-point')
void backgroundServiceEntryPoint(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();

    service.setForegroundNotificationInfo(
      title: 'GeoAlarm',
      content: 'GPS monitoring active',
    );
  }

  final locationSettings = AndroidSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 10,
    intervalDuration: const Duration(seconds: 5),
    foregroundNotificationConfig: const ForegroundNotificationConfig(
      notificationTitle: 'GeoAlarm',
      notificationText: 'GeoAlarm is monitoring your location',
      enableWakeLock: true,
    ),
  );

  Position? previousPosition;

  final triggeredStates = <String, bool>{};

  final stream = Geolocator.getPositionStream(
    locationSettings: locationSettings,
  );

  stream.listen(
    (position) async {
      try {
        final prefs = await SharedPreferences.getInstance();

        final saved = prefs.getString(alarmsKey);

        if (saved == null) {
          previousPosition = position;
          return;
        }

        final decoded = jsonDecode(saved);

        if (decoded is! List) {
          previousPosition = position;
          return;
        }

        for (final item in decoded) {
          if (item is! Map) continue;

          final alarm = Map<String, dynamic>.from(item);

          final location = alarm['location']?.toString() ?? '';

          final parts = location.split(',');

          if (parts.length < 2) continue;

          final latitude = double.tryParse(parts[0].trim());
          final longitude = double.tryParse(parts[1].trim());

          if (latitude == null || longitude == null) continue;

          final radius = double.tryParse('${alarm['radius'] ?? 100}') ?? 100;

          final arrival = alarm['onArrival'] == true;

          final id = alarmIdentifier(alarm);

          final distance = Geolocator.distanceBetween(
            position.latitude,
            position.longitude,
            latitude,
            longitude,
          );

          final inside = distance <= radius;

          bool previousInside = false;

          if (previousPosition != null) {
            final previousDistance = Geolocator.distanceBetween(
              previousPosition!.latitude,
              previousPosition!.longitude,
              latitude,
              longitude,
            );

            previousInside = previousDistance <= radius;
          }

          bool triggered = false;

          if (previousPosition != null) {
            if (arrival && !previousInside && inside) {
              triggered = true;
            }

            if (!arrival && previousInside && !inside) {
              triggered = true;
            }
          }

          if (triggered) {
            if (triggeredStates[id] != true) {
              final trigger = {
                'name': alarm['name'] ?? 'GeoAlarm',
                'location': location,
                'timestamp': DateTime.now().millisecondsSinceEpoch,
              };

              await prefs.setString(triggerKey, jsonEncode(trigger));

              triggeredStates[id] = true;

              service.invoke('alarmTriggered', trigger);
            }
          } else {
            if (arrival && inside) {
              triggeredStates[id] = true;
            } else if (!arrival && !inside) {
              triggeredStates[id] = true;
            } else {
              triggeredStates[id] = false;
            }
          }
        }

        previousPosition = position;
      } catch (e) {
        debugPrint('Background GPS error: $e');
      }
    },
    onError: (error) {
      debugPrint('Location stream error: $error');
    },
  );

  service.on('stopService').listen((event) {
    service.stopSelf();
  });
}

Future<void> initializeNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

  const settings = InitializationSettings(android: androidSettings);

  await notifications.initialize(settings);

  final android = notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  await android?.requestNotificationsPermission();

  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      serviceChannelId,
      'GeoAlarm GPS Monitoring',
      description: 'Notification shown while GeoAlarm monitors your location.',
      importance: Importance.low,
      playSound: false,
    ),
  );

  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      alarmChannelId,
      'GeoAlarm Alarms',
      description:
          'Notifications produced when a GeoAlarm location is reached.',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('geoalarm_alarm'),
    ),
  );
}

Future<void> showAlarmNotification(String alarmName) async {
  const androidDetails = AndroidNotificationDetails(
    alarmChannelId,
    'GeoAlarm Alarms',
    channelDescription:
        'Notifications produced when a location alarm is triggered.',
    importance: Importance.max,
    priority: Priority.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('geoalarm_alarm'),
    enableVibration: true,
    fullScreenIntent: true,
    category: AndroidNotificationCategory.alarm,
  );

  const details = NotificationDetails(android: androidDetails);

  await notifications.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000,
    '🚨 GeoAlarm',
    '$alarmName triggered',
    details,
  );
}

Future<void> configureBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundServiceEntryPoint,
      autoStart: false,
      autoStartOnBoot: false,
      isForegroundMode: true,
      notificationChannelId: serviceChannelId,
      initialNotificationTitle: 'GeoAlarm',
      initialNotificationContent: 'GPS monitoring active',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: backgroundServiceEntryPoint,
      onBackground: (_) async {
        return true;
      },
    ),
  );
}

Future<void> startBackgroundService() async {
  final service = FlutterBackgroundService();

  if (!await service.isRunning()) {
    await service.startService();
  }
}

Future<void> stopBackgroundService() async {
  final service = FlutterBackgroundService();

  if (await service.isRunning()) {
    service.invoke('stopService');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initializeNotifications();

  await configureBackgroundService();

  runApp(const GeoAlarmApp());
}

class GeoAlarmApp extends StatelessWidget {
  const GeoAlarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GeoAlarm',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<Map<String, dynamic>> activeAlarms = [];

  bool gpsMonitoring = false;

  Timer? serviceTimer;
  Timer? triggerTimer;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    loadAlarms();
    updateServiceStatus();

    serviceTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => updateServiceStatus(),
    );

    triggerTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => checkBackgroundTrigger(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    serviceTimer?.cancel();
    triggerTimer?.cancel();

    audioPlayer.dispose();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      updateServiceStatus();
    }
  }

  Future<void> updateServiceStatus() async {
    try {
      final running = await FlutterBackgroundService().isRunning();

      if (!mounted) return;

      if (running != gpsMonitoring) {
        setState(() {
          gpsMonitoring = running;
        });
      }
    } catch (_) {}
  }

  Future<void> loadAlarms() async {
    final prefs = await SharedPreferences.getInstance();

    final saved = prefs.getString(alarmsKey);

    if (saved == null) return;

    try {
      final decoded = jsonDecode(saved);

      if (decoded is! List) return;

      final alarms = decoded
          .whereType<Map>()
          .map((alarm) => Map<String, dynamic>.from(alarm))
          .toList();

      if (!mounted) return;

      setState(() {
        activeAlarms = alarms;
      });
    } catch (e) {
      debugPrint('Alarm loading error: $e');
    }
  }

  Future<void> saveAlarms() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(alarmsKey, jsonEncode(activeAlarms));
  }

  Future<void> checkBackgroundTrigger() async {
    final prefs = await SharedPreferences.getInstance();

    final trigger = prefs.getString(triggerKey);

    if (trigger == null) return;

    await prefs.remove(triggerKey);

    try {
      final data = jsonDecode(trigger);

      final name = data['name']?.toString() ?? 'GeoAlarm';

      await showAlarmNotification(name);

      await audioPlayer.stop();

      await audioPlayer.play(AssetSource('sounds/geoalarm_alarm.wav'));
    } catch (e) {
      debugPrint('Alarm playback error: $e');
    }
  }

  Future<void> startGps() async {
    final enabled = await Geolocator.isLocationServiceEnabled();

    if (!enabled) {
      if (!mounted) return;

      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('GPS is disabled'),
          content: const Text(
            'Please turn on Location/GPS in your phone settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );

      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Location permission is required for GeoAlarm.'),
        ),
      );

      return;
    }

    if (permission == LocationPermission.whileInUse) {
      if (!mounted) return;

      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Background location'),
          content: const Text(
            'GeoAlarm needs background location permission '
            'to monitor your alarms when the app is not open.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Continue'),
            ),
          ],
        ),
      );

      permission = await Geolocator.requestPermission();
    }

    await startBackgroundService();

    await Future.delayed(const Duration(milliseconds: 700));

    await updateServiceStatus();
  }

  Future<void> stopGps() async {
    await stopBackgroundService();

    await Future.delayed(const Duration(milliseconds: 700));

    await updateServiceStatus();
  }

  Future<void> addAlarm() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => const AddAlarmScreen()),
    );

    if (result == null) return;

    setState(() {
      activeAlarms.add(result);
    });

    await saveAlarms();
  }

  Future<void> editAlarm(int index) async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => AddAlarmScreen(existingAlarm: activeAlarms[index]),
      ),
    );

    if (result == null) return;

    setState(() {
      activeAlarms[index] = result;
    });

    await saveAlarms();
  }

  Future<void> deleteAlarm(int index) async {
    final alarm = activeAlarms[index];

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete alarm?'),
        content: Text('Delete "${alarm['name'] ?? 'this alarm'}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      activeAlarms.removeAt(index);
    });

    await saveAlarms();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GeoAlarm'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      gpsMonitoring ? Icons.gps_fixed : Icons.gps_off,
                      size: 32,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        gpsMonitoring
                            ? 'GPS monitoring active in background'
                            : 'GPS monitoring stopped',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: gpsMonitoring ? null : startGps,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('START GPS'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: gpsMonitoring ? stopGps : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('STOP GPS'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: activeAlarms.isEmpty
                  ? const Center(
                      child: Text(
                        'No alarms yet.\nTap + to create one.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: activeAlarms.length,
                      itemBuilder: (_, index) {
                        final alarm = activeAlarms[index];

                        final arrival = alarm['onArrival'] == true;

                        return Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Icon(arrival ? Icons.login : Icons.logout),
                            ),
                            title: Text(alarm['name'] ?? 'Unnamed Alarm'),
                            subtitle: Text(
                              '${alarm['location'] ?? 'Unknown'}\n'
                              '${arrival ? 'Arrival' : 'Leaving'} • '
                              '${(alarm['radius'] ?? 100).round()} m',
                            ),
                            isThreeLine: true,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit),
                                  onPressed: () => editAlarm(index),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete),
                                  onPressed: () => deleteAlarm(index),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: addAlarm,
        child: const Icon(Icons.add),
      ),
    );
  }
}
