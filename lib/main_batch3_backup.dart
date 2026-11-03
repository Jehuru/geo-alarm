import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'add_alarm_screen.dart';
import 'alarm_map_screen.dart';
import 'alarm_alert_screen.dart';

const String alarmsStorageKey = 'alarms';
const String pendingAlarmNameKey = 'pendingAlarmName';
const String snoozeAlarmNameKey = 'snoozeAlarmName';
const String snoozeUntilKey = 'snoozeUntilMillis';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
bool alarmAlertIsOpen = false;

void openAlarmAlert(String alarmName) {
  final navigator = navigatorKey.currentState;
  if (navigator == null || alarmAlertIsOpen) return;
  alarmAlertIsOpen = true;
  // Avoid stacking duplicate alert screens when both the app and notification
  // callbacks receive the same alarm.
  navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => AlarmAlertScreen(
        alarmName: alarmName,
        onStop: stopCurrentAlarm,
        onSnooze: () => snoozeCurrentAlarm(alarmName),
        onClose: () => alarmAlertIsOpen = false,
      ),
      fullscreenDialog: true,
    ),
  );
}

Future<void> stopCurrentAlarm() async {
  try {
    await audioPlayer.stop();
    await audioPlayer.setReleaseMode(ReleaseMode.release);
  } catch (_) {}
  await notifications.cancelAll();
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(pendingAlarmNameKey);
}

Future<void> snoozeCurrentAlarm(String alarmName) async {
  try {
    await audioPlayer.stop();
    await audioPlayer.setReleaseMode(ReleaseMode.release);
  } catch (_) {}
  await notifications.cancelAll();

  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(pendingAlarmNameKey);
  await prefs.setString(snoozeAlarmNameKey, alarmName);
  await prefs.setInt(
    snoozeUntilKey,
    DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
  );

  final value = prefs.getString(alarmsStorageKey);
  if (value != null) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        final alarms = decoded
            .map<Map<String, dynamic>>(
              (item) => Map<String, dynamic>.from(item as Map),
            )
            .toList();
        for (final alarm in alarms) {
          if ((alarm['name']?.toString() ?? 'GeoAlarm') == alarmName) {
            alarm['triggered'] = false;
            alarm['snoozedUntil'] = DateTime.now()
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch;
            break;
          }
        }
        await prefs.setString(alarmsStorageKey, jsonEncode(alarms));
      }
    } catch (_) {}
  }
}

const String notificationChannelId = 'geoalarm_channel';
const String notificationChannelName = 'GeoAlarm';
const String notificationChannelDescription =
    'GeoAlarm location monitoring notifications';

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

final AudioPlayer audioPlayer = AudioPlayer();

Future<void> initializeNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

  const settings = InitializationSettings(android: androidSettings);

  await notifications.initialize(
    settings,
    onDidReceiveNotificationResponse: (response) {
      final name = response.payload;
      if (name != null && name.isNotEmpty) {
        openAlarmAlert(name);
      }
    },
  );

  const channel = AndroidNotificationChannel(
    notificationChannelId,
    notificationChannelName,
    description: notificationChannelDescription,
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('geoalarm_alarm'),
  );

  await notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.requestNotificationsPermission();
}

Future<void> triggerAlarm(String alarmName) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(pendingAlarmNameKey, alarmName);

  // If the app is currently open, show the full-screen in-app alert too.
  openAlarmAlert(alarmName);

  // Start the Flutter audio as an additional foreground/active-app backup.
  try {
    await audioPlayer.stop();
    await audioPlayer.setReleaseMode(ReleaseMode.loop);
    await audioPlayer.play(AssetSource('sounds/geoalarm_alarm.wav'));

    Future.delayed(const Duration(seconds: 30), () async {
      try {
        await audioPlayer.stop();
        await audioPlayer.setReleaseMode(ReleaseMode.release);
      } catch (_) {}
    });
  } catch (_) {}

  // Android notification uses the 30-second raw WAV file.
  try {
    await notifications.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      'GeoAlarm',
      alarmName,
      NotificationDetails(
        android: AndroidNotificationDetails(
          notificationChannelId,
          notificationChannelName,
          channelDescription: notificationChannelDescription,
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('geoalarm_alarm'),
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
          ongoing: true,
          autoCancel: false,
        ),
      ),
      payload: alarmName,
    );
  } catch (_) {}
}

double calculateDistanceMeters(
  Position position,
  double latitude,
  double longitude,
) {
  return Geolocator.distanceBetween(
    position.latitude,
    position.longitude,
    latitude,
    longitude,
  );
}

String formatDistance(double meters) {
  if (meters < 1000) {
    return '${meters.round()} m';
  }

  return '${(meters / 1000).toStringAsFixed(2)} km';
}

String getAlarmStatus({
  required Map<String, dynamic> alarm,
  required Position? position,
  required bool gpsRunning,
}) {
  if (!gpsRunning || position == null) {
    return 'GPS inactive';
  }

  if (alarm['enabled'] == false) {
    return 'Paused';
  }

  if (alarm['triggered'] == true) {
    return 'Triggered';
  }

  final latitude = (alarm['latitude'] as num?)?.toDouble();

  final longitude = (alarm['longitude'] as num?)?.toDouble();

  if (latitude == null || longitude == null) {
    return 'Armed';
  }

  final radius = (alarm['radius'] as num?)?.toDouble() ?? 100;

  final distance = calculateDistanceMeters(position, latitude, longitude);

  final inside = distance <= radius;
  final onArrival = alarm['onArrival'] == true;
  final wasInside = alarm['wasInside'] == true;

  if (onArrival) {
    if (inside) {
      return 'Inside radius';
    }

    return 'Armed';
  }

  if (wasInside && !inside) {
    return 'Leave detected';
  }

  if (inside) {
    return 'Waiting to leave';
  }

  return 'Waiting to enter';
}

Color getStatusColor(String status) {
  switch (status) {
    case 'Triggered':
    case 'Leave detected':
      return Colors.red;

    case 'Inside radius':
      return Colors.blue;

    case 'Waiting to leave':
      return Colors.orange;

    case 'GPS inactive':
    case 'Paused':
      return Colors.grey;

    case 'Waiting to enter':
      return Colors.deepPurple;

    default:
      return Colors.green;
  }
}

IconData getStatusIcon(String status) {
  switch (status) {
    case 'Triggered':
      return Icons.notifications_active;

    case 'Inside radius':
      return Icons.location_on;

    case 'Waiting to leave':
      return Icons.directions_walk;

    case 'Leave detected':
      return Icons.logout;

    case 'GPS inactive':
      return Icons.gps_off;

    case 'Paused':
      return Icons.pause_circle;

    case 'Waiting to enter':
      return Icons.location_searching;

    default:
      return Icons.shield_outlined;
  }
}

@pragma('vm:entry-point')
void backgroundServiceEntryPoint(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();

  Timer.periodic(const Duration(seconds: 5), (timer) async {
    try {
      final snoozeName = prefs.getString(snoozeAlarmNameKey);
      final snoozeUntil = prefs.getInt(snoozeUntilKey);
      if (snoozeName != null &&
          snoozeUntil != null &&
          DateTime.now().millisecondsSinceEpoch >= snoozeUntil) {
        await prefs.remove(snoozeAlarmNameKey);
        await prefs.remove(snoozeUntilKey);

        final storedAlarms = prefs.getString(alarmsStorageKey);
        if (storedAlarms != null) {
          try {
            final decodedAlarms = jsonDecode(storedAlarms);
            if (decodedAlarms is List) {
              final updatedAlarms = decodedAlarms
                  .map<Map<String, dynamic>>(
                    (item) => Map<String, dynamic>.from(item as Map),
                  )
                  .toList();
              for (final alarm in updatedAlarms) {
                if ((alarm['name']?.toString() ?? 'GeoAlarm') == snoozeName) {
                  alarm['triggered'] = true;
                  alarm.remove('snoozedUntil');
                  break;
                }
              }
              await prefs.setString(
                alarmsStorageKey,
                jsonEncode(updatedAlarms),
              );
            }
          } catch (_) {}
        }

        await triggerAlarm(snoozeName);
        return;
      }

      final alarmsString = prefs.getString(alarmsStorageKey);

      if (alarmsString == null) {
        return;
      }

      final decoded = jsonDecode(alarmsString);

      if (decoded is! List) {
        return;
      }

      final alarms = decoded
          .map<Map<String, dynamic>>(
            (item) => Map<String, dynamic>.from(item as Map),
          )
          .toList();

      bool changed = false;

      final permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      for (final alarm in alarms) {
        if (alarm['enabled'] == false) {
          continue;
        }

        if (alarm['triggered'] == true) {
          continue;
        }

        final snoozedUntil = (alarm['snoozedUntil'] as num?)?.toInt();
        if (snoozedUntil != null &&
            DateTime.now().millisecondsSinceEpoch < snoozedUntil) {
          continue;
        }

        final latitude = (alarm['latitude'] as num?)?.toDouble();

        final longitude = (alarm['longitude'] as num?)?.toDouble();

        if (latitude == null || longitude == null) {
          continue;
        }

        final radius = (alarm['radius'] as num?)?.toDouble() ?? 100;

        final distance = calculateDistanceMeters(position, latitude, longitude);

        final isInside = distance <= radius;

        final onArrival = alarm['onArrival'] == true;

        final wasInside = alarm['wasInside'] == true;

        if (onArrival) {
          if (isInside) {
            await triggerAlarm(alarm['name']?.toString() ?? 'GeoAlarm');

            alarm['triggered'] = true;
            changed = true;
          }
        } else {
          if (!wasInside && isInside) {
            alarm['wasInside'] = true;
            changed = true;
          } else if (wasInside && !isInside) {
            await triggerAlarm(alarm['name']?.toString() ?? 'GeoAlarm');

            alarm['triggered'] = true;
            alarm['wasInside'] = false;
            changed = true;
          }
        }
      }

      if (changed) {
        await prefs.setString(alarmsStorageKey, jsonEncode(alarms));
      }
    } catch (_) {}
  });

  service.on('stopService').listen((event) {
    service.stopSelf();
  });
}

Future<void> startBackgroundService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundServiceEntryPoint,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: 'GeoAlarm',
      initialNotificationContent: 'GPS monitoring active',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );

  await service.startService();
}

Future<void> stopBackgroundService() async {
  final service = FlutterBackgroundService();

  service.invoke('stopService');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initializeNotifications();

  runApp(const GeoAlarmApp());
}

class GeoAlarmApp extends StatelessWidget {
  const GeoAlarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'GeoAlarm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> alarms = [];

  StreamSubscription<Position>? positionSubscription;

  Position? currentPosition;

  bool gpsRunning = false;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    loadAlarms();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showPendingAlarmIfNeeded();
    });
  }

  Future<void> _showPendingAlarmIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final alarmName = prefs.getString(pendingAlarmNameKey);
    if (alarmName != null && alarmName.isNotEmpty && mounted) {
      openAlarmAlert(alarmName);
    }
  }

  @override
  void dispose() {
    positionSubscription?.cancel();
    super.dispose();
  }

  Future<void> loadAlarms() async {
    final prefs = await SharedPreferences.getInstance();

    final value = prefs.getString(alarmsStorageKey);

    if (value != null) {
      try {
        final decoded = jsonDecode(value);

        if (decoded is List) {
          alarms = decoded
              .map<Map<String, dynamic>>(
                (item) => Map<String, dynamic>.from(item as Map),
              )
              .toList();
        }
      } catch (_) {}
    }

    bool normalized = false;

    for (final alarm in alarms) {
      if (!alarm.containsKey('enabled')) {
        alarm['enabled'] = true;
        normalized = true;
      }

      if (!alarm.containsKey('wasInside')) {
        alarm['wasInside'] = false;
        normalized = true;
      }

      if (!alarm.containsKey('triggered')) {
        alarm['triggered'] = false;
        normalized = true;
      }
    }

    if (normalized) {
      await saveAlarms();
    }

    if (!mounted) return;

    setState(() {
      loading = false;
    });
  }

  Future<void> saveAlarms() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(alarmsStorageKey, jsonEncode(alarms));
  }

  Future<bool> checkLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      if (!mounted) return false;

      await showDialog(
        context: context,
        builder: (_) {
          return AlertDialog(
            title: const Text('Location is disabled'),
            content: const Text(
              'Please enable GPS/location services '
              'to use GeoAlarm.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );

      return false;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return false;
    }

    return true;
  }

  Future<void> startGps() async {
    final allowed = await checkLocationPermission();

    if (!allowed) return;

    await positionSubscription?.cancel();

    positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen(_handlePosition);

    try {
      currentPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
    } catch (_) {}

    await startBackgroundService();

    if (!mounted) return;

    setState(() {
      gpsRunning = true;
    });
  }

  Future<void> stopGps() async {
    await positionSubscription?.cancel();

    positionSubscription = null;

    await stopBackgroundService();

    if (!mounted) return;

    setState(() {
      gpsRunning = false;
    });
  }

  Future<void> _handlePosition(Position position) async {
    currentPosition = position;

    bool changed = false;

    for (final alarm in alarms) {
      if (alarm['enabled'] == false) {
        continue;
      }

      if (alarm['triggered'] == true) {
        continue;
      }

      final latitude = (alarm['latitude'] as num?)?.toDouble();

      final longitude = (alarm['longitude'] as num?)?.toDouble();

      if (latitude == null || longitude == null) {
        continue;
      }

      final radius = (alarm['radius'] as num?)?.toDouble() ?? 100;

      final distance = calculateDistanceMeters(position, latitude, longitude);

      final isInside = distance <= radius;

      final onArrival = alarm['onArrival'] == true;

      final wasInside = alarm['wasInside'] == true;

      if (onArrival) {
        if (isInside) {
          await triggerAlarm(alarm['name']?.toString() ?? 'GeoAlarm');

          alarm['triggered'] = true;
          changed = true;
        }
      } else {
        if (!wasInside && isInside) {
          alarm['wasInside'] = true;
          changed = true;
        } else if (wasInside && !isInside) {
          await triggerAlarm(alarm['name']?.toString() ?? 'GeoAlarm');

          alarm['triggered'] = true;
          alarm['wasInside'] = false;
          changed = true;
        }
      }
    }

    if (changed) {
      await saveAlarms();
    }

    if (!mounted) return;

    setState(() {});
  }

  Future<void> stopAlarmSound() async {
    await stopCurrentAlarm();
  }

  Future<void> toggleAlarm(int index) async {
    final alarm = alarms[index];

    alarm['enabled'] = alarm['enabled'] == false;

    await saveAlarms();

    if (!mounted) return;

    setState(() {});
  }

  Future<void> resetAlarm(int index) async {
    final alarm = alarms[index];

    alarm['triggered'] = false;
    alarm['wasInside'] = false;
    alarm['enabled'] = true;

    await saveAlarms();

    if (!mounted) return;

    setState(() {});
  }

  Future<void> deleteAlarm(int index) async {
    final alarm = alarms[index];

    final name = alarm['name']?.toString() ?? 'this alarm';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('Delete alarm?'),
          content: Text(
            'Are you sure you want to delete '
            '"$name"?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('DELETE'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    alarms.removeAt(index);

    await saveAlarms();

    if (!mounted) return;

    setState(() {});
  }

  // FIXED: Add Alarm now saves through the normal
  // SharedPreferences flow and Home immediately
  // reloads the persisted alarm list.
  Future<void> openAddAlarm() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => const AddAlarmScreen()),
    );

    if (result == null) return;

    result.putIfAbsent('enabled', () => true);

    result.putIfAbsent('triggered', () => false);

    result.putIfAbsent('wasInside', () => false);

    alarms.add(result);

    await saveAlarms();

    // IMPORTANT:
    // Reload from SharedPreferences instead
    // of relying only on the in-memory list.
    await loadAlarms();
  }

  // FIXED: Editing an alarm now also reloads
  // the persisted list after saving.
  Future<void> editAlarm(Map<String, dynamic> alarm) async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => AddAlarmScreen(existingAlarm: alarm)),
    );

    if (result == null) return;

    result.putIfAbsent('enabled', () => true);

    result.putIfAbsent('triggered', () => false);

    result.putIfAbsent('wasInside', () => false);

    final index = alarms.indexOf(alarm);

    if (index >= 0) {
      alarms[index] = result;
    } else {
      alarms.add(result);
    }

    await saveAlarms();

    await loadAlarms();
  }

  void openMap(Map<String, dynamic> alarm) {
    final latitude = (alarm['latitude'] as num?)?.toDouble();

    final longitude = (alarm['longitude'] as num?)?.toDouble();

    final radius = (alarm['radius'] as num?)?.toDouble() ?? 100;

    if (latitude == null || longitude == null) {
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) {
          return AlarmMapScreen(
            alarmName: alarm['name']?.toString() ?? 'GeoAlarm',
            destinationLatitude: latitude,
            destinationLongitude: longitude,
            radius: radius,
          );
        },
      ),
    );
  }

  Widget buildStatusChip(Map<String, dynamic> alarm) {
    final status = getAlarmStatus(
      alarm: alarm,
      position: currentPosition,
      gpsRunning: gpsRunning,
    );

    final color = getStatusColor(status);

    final icon = getStatusIcon(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 5),
          Text(
            status,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget buildAlarmCard(Map<String, dynamic> alarm, int index) {
    final latitude = (alarm['latitude'] as num?)?.toDouble();

    final longitude = (alarm['longitude'] as num?)?.toDouble();

    double? distance;

    if (currentPosition != null && latitude != null && longitude != null) {
      distance = calculateDistanceMeters(currentPosition!, latitude, longitude);
    }

    final radius = (alarm['radius'] as num?)?.toDouble() ?? 100;

    final onArrival = alarm['onArrival'] == true;

    final enabled = alarm['enabled'] != false;

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 24,
                  child: Icon(onArrival ? Icons.login : Icons.logout),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        alarm['name']?.toString() ?? 'GeoAlarm',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        onArrival ? 'I arrive' : 'I leave',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                buildStatusChip(alarm),
              ],
            ),
            const SizedBox(height: 14),
            if (distance != null)
              Row(
                children: [
                  const Icon(Icons.near_me, size: 18),
                  const SizedBox(width: 7),
                  Text(
                    '${formatDistance(distance)} away',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 15),
                  const Icon(Icons.radio_button_checked, size: 16),
                  const SizedBox(width: 5),
                  Text('${radius.round()} m radius'),
                ],
              )
            else
              Row(
                children: [
                  const Icon(Icons.radio_button_checked, size: 18),
                  const SizedBox(width: 7),
                  Text('${radius.round()} m radius'),
                ],
              ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => openMap(alarm),
                icon: const Icon(Icons.map),
                label: const Text('OPEN LIVE MAP'),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => toggleAlarm(index),
                    icon: Icon(enabled ? Icons.pause : Icons.play_arrow),
                    label: Text(enabled ? 'PAUSE' : 'ACTIVATE'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => resetAlarm(index),
                    icon: const Icon(Icons.refresh),
                    label: const Text('RESET'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => editAlarm(alarm),
                    icon: const Icon(Icons.edit),
                    label: const Text('EDIT'),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => deleteAlarm(index),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('DELETE'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget buildGpsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: gpsRunning
                      ? Colors.green.withValues(alpha: 0.15)
                      : Colors.grey.withValues(alpha: 0.15),
                  child: Icon(
                    gpsRunning ? Icons.gps_fixed : Icons.gps_off,
                    color: gpsRunning ? Colors.green : Colors.grey,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'GPS Monitoring',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        gpsRunning
                            ? 'Location monitoring is active'
                            : 'Location monitoring is stopped',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: gpsRunning,
                  onChanged: (value) {
                    if (value) {
                      startGps();
                    } else {
                      stopGps();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: gpsRunning ? stopGps : startGps,
                icon: Icon(gpsRunning ? Icons.stop : Icons.play_arrow),
                label: Text(gpsRunning ? 'STOP GPS' : 'START GPS'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'GeoAlarm',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () async {
              await loadAlarms();

              if (mounted) {
                setState(() {});
              }
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: loadAlarms,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  buildGpsCard(),

                  if (alarms.any((alarm) => alarm['triggered'] == true)) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: stopAlarmSound,
                        icon: const Icon(Icons.volume_off),
                        label: const Text('STOP ALARM SOUND'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 22),

                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'My Alarms',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: openAddAlarm,
                        icon: const Icon(Icons.add),
                        label: const Text('ADD'),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  if (alarms.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(30),
                        child: Column(
                          children: [
                            Icon(
                              Icons.alarm_add,
                              size: 55,
                              color: Colors.grey.shade500,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'No alarms yet',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Create a location alarm to get started.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey.shade700),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: openAddAlarm,
                              icon: const Icon(Icons.add),
                              label: const Text('CREATE ALARM'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ...List.generate(
                      alarms.length,
                      (index) => buildAlarmCard(alarms[index], index),
                    ),
                ],
              ),
            ),
      floatingActionButton: alarms.isNotEmpty
          ? FloatingActionButton(
              onPressed: openAddAlarm,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
