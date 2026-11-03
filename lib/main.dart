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
import 'alarm_history_screen.dart';
import 'feature_center_screen.dart';

const String alarmsStorageKey = 'alarms';
const String pendingAlarmNameKey = 'pendingAlarmName';
const String snoozeAlarmNameKey = 'snoozeAlarmName';
const String snoozeUntilKey = 'snoozeUntilMillis';
const String stoppedAlarmNamesKey = 'stoppedAlarmNames';
const String stoppedAlarmUntilKey = 'stoppedAlarmUntilMillis';

const String alarmHistoryStorageKey = 'alarmHistory';

Future<void> recordAlarmHistory(Map<String, dynamic> alarm) async {
  final prefs = await SharedPreferences.getInstance();
  final now = DateTime.now();
  final name = alarm['name']?.toString() ?? 'GeoAlarm';
  final existingRaw = prefs.getString(alarmHistoryStorageKey);
  List<Map<String, dynamic>> history = [];

  if (existingRaw != null) {
    try {
      final decoded = jsonDecode(existingRaw);
      if (decoded is List) {
        history = decoded
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      }
    } catch (_) {}
  }

  // Foreground and background GPS monitors can see the same trigger.
  // Ignore a duplicate entry for the same alarm within 20 seconds.
  final duplicate = history.any((entry) {
    final timestamp = int.tryParse(entry['timestamp']?.toString() ?? '');
    return entry['name']?.toString() == name &&
        timestamp != null &&
        now.millisecondsSinceEpoch - timestamp >= 0 &&
        now.millisecondsSinceEpoch - timestamp < 20000;
  });
  if (duplicate) return;

  history.insert(0, <String, dynamic>{
    'name': name,
    'timestamp': now.millisecondsSinceEpoch,
    'onArrival': alarm['onArrival'] == true,
    'latitude': alarm['latitude'],
    'longitude': alarm['longitude'],
    'radius': alarm['radius'] ?? 100,
    'repeatDaily': alarm['repeatDaily'] == true,
  });

  if (history.length > 200) {
    history = history.take(200).toList();
  }
  await prefs.setString(alarmHistoryStorageKey, jsonEncode(history));
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
bool alarmAlertIsOpen = false;
Timer? foregroundSnoozeTimer;

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

Future<bool> _isAlarmStopped(SharedPreferences prefs, String alarmName) async {
  final until = prefs.getInt(stoppedAlarmUntilKey) ?? 0;
  if (DateTime.now().millisecondsSinceEpoch >= until) {
    await prefs.remove(stoppedAlarmNamesKey);
    await prefs.remove(stoppedAlarmUntilKey);
    return false;
  }

  final rawNames = prefs.getString(stoppedAlarmNamesKey);
  if (rawNames == null) return false;
  try {
    final decoded = jsonDecode(rawNames);
    return decoded is List &&
        decoded.map((e) => e.toString()).contains(alarmName);
  } catch (_) {
    return false;
  }
}

Future<void> stopCurrentAlarm() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();

  // Latch the stop action so a concurrent foreground/background GPS check
  // cannot immediately restart the same alarm.
  final names = <String>{};
  final pendingName = prefs.getString(pendingAlarmNameKey);
  if (pendingName != null && pendingName.isNotEmpty) names.add(pendingName);

  final stored = prefs.getString(alarmsStorageKey);
  if (stored != null) {
    try {
      final decoded = jsonDecode(stored);
      if (decoded is List) {
        for (final item in decoded.whereType<Map>()) {
          if (item['triggered'] == true) {
            names.add(item['name']?.toString() ?? 'GeoAlarm');
          }
        }
      }
    } catch (_) {}
  }

  if (names.isNotEmpty) {
    await prefs.setString(stoppedAlarmNamesKey, jsonEncode(names.toList()));
    await prefs.setInt(
      stoppedAlarmUntilKey,
      DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch,
    );
  }

  await prefs.remove(pendingAlarmNameKey);
  await prefs.remove(snoozeAlarmNameKey);
  await prefs.remove(snoozeUntilKey);

  try {
    await audioPlayer.stop();
    await audioPlayer.setReleaseMode(ReleaseMode.release);
  } catch (_) {}
  await notifications.cancelAll();
}

Future<void> snoozeCurrentAlarm(String alarmName) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();

  // Remove this alarm from any previous STOP latch.
  final rawStopped = prefs.getString(stoppedAlarmNamesKey);
  if (rawStopped != null) {
    try {
      final decoded = jsonDecode(rawStopped);
      if (decoded is List) {
        final remaining = decoded
            .map((item) => item.toString())
            .where((name) => name != alarmName)
            .toList();

        if (remaining.isEmpty) {
          await prefs.remove(stoppedAlarmNamesKey);
          await prefs.remove(stoppedAlarmUntilKey);
        } else {
          await prefs.setString(stoppedAlarmNamesKey, jsonEncode(remaining));
        }
      }
    } catch (_) {}
  }

  // Stop the current alarm sound and notification.
  foregroundSnoozeTimer?.cancel();

  try {
    await audioPlayer.stop();
    await audioPlayer.setReleaseMode(ReleaseMode.release);
  } catch (_) {}

  await notifications.cancelAll();

  final snoozeUntil = DateTime.now()
      .add(const Duration(minutes: 5))
      .millisecondsSinceEpoch;

  await prefs.remove(pendingAlarmNameKey);
  await prefs.setString(snoozeAlarmNameKey, alarmName);
  await prefs.setInt(snoozeUntilKey, snoozeUntil);

  // Save the snooze time on the matching alarm.
  final value = prefs.getString(alarmsStorageKey);

  if (value != null) {
    try {
      final decoded = jsonDecode(value);

      if (decoded is List) {
        final alarms = decoded
            .whereType<Map>()
            .map<Map<String, dynamic>>(
              (item) => Map<String, dynamic>.from(item),
            )
            .toList();

        for (final alarm in alarms) {
          if ((alarm['name']?.toString() ?? 'GeoAlarm') == alarmName) {
            alarm['triggered'] = false;
            alarm['snoozedUntil'] = snoozeUntil;
            break;
          }
        }

        await prefs.setString(alarmsStorageKey, jsonEncode(alarms));
      }
    } catch (_) {}
  }

  // Backup for when the app's foreground isolate is still alive.
  // The background service remains responsible for the normal expiry.
  foregroundSnoozeTimer = Timer(
    const Duration(minutes: 5, seconds: 10),
    () async {
      try {
        await prefs.reload();

        final savedName = prefs.getString(snoozeAlarmNameKey);
        final savedUntil = prefs.getInt(snoozeUntilKey);
        final now = DateTime.now().millisecondsSinceEpoch;

        // If the background service already handled the snooze,
        // these keys will have been cleared.
        if (savedName != alarmName || savedUntil == null || now < savedUntil) {
          return;
        }

        // Claim the pending snooze before firing it.
        await prefs.remove(snoozeAlarmNameKey);
        await prefs.remove(snoozeUntilKey);

        final storedAlarms = prefs.getString(alarmsStorageKey);

        if (storedAlarms != null) {
          try {
            final decoded = jsonDecode(storedAlarms);

            if (decoded is List) {
              final alarms = decoded
                  .whereType<Map>()
                  .map<Map<String, dynamic>>(
                    (item) => Map<String, dynamic>.from(item),
                  )
                  .toList();

              for (final alarm in alarms) {
                if ((alarm['name']?.toString() ?? 'GeoAlarm') == alarmName) {
                  await recordAlarmHistory(alarm);
                  markAlarmTriggered(alarm);
                  alarm.remove('snoozedUntil');
                  break;
                }
              }

              await prefs.setString(alarmsStorageKey, jsonEncode(alarms));
            }
          } catch (_) {}
        }

        await triggerAlarm(alarmName, playForegroundAudio: true);
      } catch (_) {}
    },
  );
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

Future<void> triggerAlarm(
  String alarmName, {
  bool playForegroundAudio = true,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();

  // Respect stop and snooze requests before starting any sound/notification.
  if (await _isAlarmStopped(prefs, alarmName)) return;
  final snoozedName = prefs.getString(snoozeAlarmNameKey);
  final snoozeUntil = prefs.getInt(snoozeUntilKey) ?? 0;
  if (snoozedName == alarmName &&
      DateTime.now().millisecondsSinceEpoch < snoozeUntil) {
    return;
  }

  await prefs.setString(pendingAlarmNameKey, alarmName);
  openAlarmAlert(alarmName);

  // Only the UI isolate should own AudioPlayer. A separate AudioPlayer in the
  // background-service isolate cannot be stopped by the homepage button.
  // The Android notification supplies sound when the service triggers it.
  if (playForegroundAudio) {
    try {
      await audioPlayer.stop();
      await audioPlayer.setReleaseMode(ReleaseMode.loop);
      await audioPlayer.play(AssetSource('sounds/geoalarm_alarm.wav'));
      final ringDuration = prefs.getInt('alarmRingDurationSeconds') ?? 30;
      Future.delayed(Duration(seconds: ringDuration), () async {
        try {
          await audioPlayer.stop();
          await audioPlayer.setReleaseMode(ReleaseMode.release);
        } catch (_) {}
      });
    } catch (_) {}
  }

  // Re-check after starting audio because STOP/SNOOZE may have happened
  // while the player was starting.
  await prefs.reload();
  if (await _isAlarmStopped(prefs, alarmName)) {
    try {
      await audioPlayer.stop();
      await audioPlayer.setReleaseMode(ReleaseMode.release);
    } catch (_) {}
    await prefs.remove(pendingAlarmNameKey);
    return;
  }
  final currentSnoozeName = prefs.getString(snoozeAlarmNameKey);
  final currentSnoozeUntil = prefs.getInt(snoozeUntilKey) ?? 0;
  if (currentSnoozeName == alarmName &&
      DateTime.now().millisecondsSinceEpoch < currentSnoozeUntil) {
    try {
      await audioPlayer.stop();
      await audioPlayer.setReleaseMode(ReleaseMode.release);
    } catch (_) {}
    return;
  }

  try {
    await notifications.show(
      42001,
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
          enableVibration: prefs.getBool('alarmVibrationEnabled') ?? true,
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

  // Close the race where STOP/SNOOZE lands while the notification is posted.
  await prefs.reload();
  if (await _isAlarmStopped(prefs, alarmName) ||
      (prefs.getString(snoozeAlarmNameKey) == alarmName &&
          DateTime.now().millisecondsSinceEpoch <
              (prefs.getInt(snoozeUntilKey) ?? 0))) {
    await notifications.cancel(42001);
    try {
      await audioPlayer.stop();
      await audioPlayer.setReleaseMode(ReleaseMode.release);
    } catch (_) {}
    await prefs.remove(pendingAlarmNameKey);
  }
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

String _dateStamp(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

List<int> _repeatDaysFor(Map<String, dynamic> alarm) {
  final raw = alarm['repeatDays'];
  if (raw is List) {
    final days = raw
        .map((value) => int.tryParse(value.toString()))
        .whereType<int>()
        .where((day) => day >= 1 && day <= 7)
        .toSet()
        .toList();
    return days;
  }
  return [1, 2, 3, 4, 5, 6, 7];
}

bool isAlarmScheduleActive(Map<String, dynamic> alarm, DateTime now) {
  final repeatDaily = alarm['repeatDaily'] == true;
  final scheduleEnabled = alarm['scheduleEnabled'] == true;
  final days = _repeatDaysFor(alarm);

  // If repeat is enabled, only run on selected weekdays.
  if ((repeatDaily || scheduleEnabled) && !days.contains(now.weekday)) {
    return false;
  }

  if (!scheduleEnabled) return true;

  final start = (alarm['scheduleStartMinute'] as num?)?.toInt() ?? 0;
  final end = (alarm['scheduleEndMinute'] as num?)?.toInt() ?? 1439;
  final minute = now.hour * 60 + now.minute;

  // Supports schedules that cross midnight, e.g. 22:00–06:00.
  if (start == end) return true;
  if (start < end) return minute >= start && minute <= end;
  return minute >= start || minute <= end;
}

bool prepareRepeatAlarmForToday(Map<String, dynamic> alarm, DateTime now) {
  if (alarm['repeatDaily'] != true || alarm['triggered'] != true) {
    return false;
  }

  final today = _dateStamp(now);
  final lastTriggeredDate = alarm['lastTriggeredDate']?.toString();
  if (lastTriggeredDate == today ||
      !_repeatDaysFor(alarm).contains(now.weekday)) {
    return false;
  }

  alarm['triggered'] = false;
  alarm['wasInside'] = false;
  return true;
}

void markAlarmTriggered(Map<String, dynamic> alarm) {
  final now = DateTime.now();
  alarm['triggered'] = true;
  alarm['lastTriggeredDate'] = _dateStamp(now);
  alarm['lastTriggeredAt'] = now.millisecondsSinceEpoch;
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

  await initializeNotifications();
  final prefs = await SharedPreferences.getInstance();

  Timer.periodic(const Duration(seconds: 5), (timer) async {
    try {
      // SharedPreferences is cached per isolate; refresh to see foreground
      // STOP/SNOOZE actions immediately.
      await prefs.reload();
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
                  await recordAlarmHistory(alarm);
                  markAlarmTriggered(alarm);
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

        await triggerAlarm(snoozeName, playForegroundAudio: false);
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

        final now = DateTime.now();
        if (prepareRepeatAlarmForToday(alarm, now)) {
          changed = true;
        }
        if (!isAlarmScheduleActive(alarm, now)) {
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

        final maximumUsefulError = radius < 75 ? 75.0 : radius;
        if (position.accuracy > maximumUsefulError) {
          continue;
        }

        final distance = calculateDistanceMeters(position, latitude, longitude);

        final isInside = distance <= radius;

        final onArrival = alarm['onArrival'] == true;

        final wasInside = alarm['wasInside'] == true;

        if (onArrival) {
          if (isInside) {
            await recordAlarmHistory(alarm);
            await triggerAlarm(
              alarm['name']?.toString() ?? 'GeoAlarm',
              playForegroundAudio: false,
            );

            markAlarmTriggered(alarm);
            changed = true;
          }
        } else {
          if (!wasInside && isInside) {
            alarm['wasInside'] = true;
            changed = true;
          } else if (wasInside && !isInside) {
            await recordAlarmHistory(alarm);
            await triggerAlarm(
              alarm['name']?.toString() ?? 'GeoAlarm',
              playForegroundAudio: false,
            );

            markAlarmTriggered(alarm);
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
      if (!alarm.containsKey('favorite')) {
        alarm['favorite'] = false;
        normalized = true;
      }
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
      if (!alarm.containsKey('scheduleEnabled')) {
        alarm['scheduleEnabled'] = false;
        normalized = true;
      }
      if (!alarm.containsKey('repeatDaily')) {
        alarm['repeatDaily'] = false;
        normalized = true;
      }
      if (!alarm.containsKey('repeatDays')) {
        alarm['repeatDays'] = [1, 2, 3, 4, 5, 6, 7];
        normalized = true;
      }
      if (!alarm.containsKey('scheduleStartMinute')) {
        alarm['scheduleStartMinute'] = 0;
        normalized = true;
      }
      if (!alarm.containsKey('scheduleEndMinute')) {
        alarm['scheduleEndMinute'] = 1439;
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
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).listen(_handlePosition);

    try {
      currentPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 15),
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

      final now = DateTime.now();
      if (prepareRepeatAlarmForToday(alarm, now)) {
        changed = true;
      }
      if (!isAlarmScheduleActive(alarm, now)) {
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

      // Avoid false triggers when GPS accuracy is poorer than the alarm radius.
      // Wider-radius alarms can still use a less precise fix.
      final maximumUsefulError = radius < 75 ? 75.0 : radius;
      if (position.accuracy > maximumUsefulError) {
        continue;
      }

      final distance = calculateDistanceMeters(position, latitude, longitude);

      final isInside = distance <= radius;

      final onArrival = alarm['onArrival'] == true;

      final wasInside = alarm['wasInside'] == true;

      if (onArrival) {
        if (isInside) {
          await triggerAlarm(alarm['name']?.toString() ?? 'GeoAlarm');

          markAlarmTriggered(alarm);
          changed = true;
        }
      } else {
        if (!wasInside && isInside) {
          alarm['wasInside'] = true;
          changed = true;
        } else if (wasInside && !isInside) {
          await recordAlarmHistory(alarm);
          await triggerAlarm(alarm['name']?.toString() ?? 'GeoAlarm');

          markAlarmTriggered(alarm);
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
    alarm.remove('lastTriggeredDate');
    alarm.remove('snoozedUntil');
    alarm['enabled'] = true;

    final prefs = await SharedPreferences.getInstance();
    final stoppedRaw = prefs.getString(stoppedAlarmNamesKey);
    if (stoppedRaw != null) {
      try {
        final decoded = jsonDecode(stoppedRaw);
        if (decoded is List) {
          final remaining = decoded
              .map((item) => item.toString())
              .where(
                (name) => name != (alarm['name']?.toString() ?? 'GeoAlarm'),
              )
              .toList();
          if (remaining.isEmpty) {
            await prefs.remove(stoppedAlarmNamesKey);
            await prefs.remove(stoppedAlarmUntilKey);
          } else {
            await prefs.setString(stoppedAlarmNamesKey, jsonEncode(remaining));
          }
        }
      } catch (_) {}
    }

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

  // AddAlarmScreen returns the selected alarm with Navigator.pop(context, alarm).
  // Save that returned map here; AddAlarmScreen does not write SharedPreferences.
  Future<void> openAddAlarm() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => const AddAlarmScreen(),
      ),
    );

    if (result == null) return;

    final newAlarm = <String, dynamic>{
      ...result,
      'favorite': result['favorite'] ?? false,
      'enabled': result['enabled'] ?? true,
      'wasInside': result['wasInside'] ?? false,
      'triggered': result['triggered'] ?? false,
      'scheduleEnabled': result['scheduleEnabled'] ?? false,
      'repeatDaily': result['repeatDaily'] ?? false,
      'repeatDays': result['repeatDays'] ?? [1, 2, 3, 4, 5, 6, 7],
      'scheduleStartMinute': result['scheduleStartMinute'] ?? 0,
      'scheduleEndMinute': result['scheduleEndMinute'] ?? 1439,
    };

    // Persist first, then update the visible homepage list.
    alarms.add(newAlarm);
    await saveAlarms();

    if (!mounted) return;
    setState(() {});
  }

  // The edit screen also returns a map. Replace the original alarm and save it.
  Future<void> editAlarm(Map<String, dynamic> alarm) async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => AddAlarmScreen(existingAlarm: alarm),
      ),
    );

    if (result == null) return;

    final index = alarms.indexWhere(
      (item) =>
          item['name']?.toString() == alarm['name']?.toString() &&
          item['location']?.toString() == alarm['location']?.toString(),
    );

    final updatedAlarm = <String, dynamic>{
      ...alarm,
      ...result,
      'favorite': result['favorite'] ?? alarm['favorite'] ?? false,
      'enabled': result['enabled'] ?? alarm['enabled'] ?? true,
      'wasInside': false,
      'triggered': false,
      'scheduleEnabled':
          result['scheduleEnabled'] ?? alarm['scheduleEnabled'] ?? false,
      'repeatDaily': result['repeatDaily'] ?? alarm['repeatDaily'] ?? false,
      'repeatDays':
          result['repeatDays'] ?? alarm['repeatDays'] ?? [1, 2, 3, 4, 5, 6, 7],
      'scheduleStartMinute':
          result['scheduleStartMinute'] ?? alarm['scheduleStartMinute'] ?? 0,
      'scheduleEndMinute':
          result['scheduleEndMinute'] ?? alarm['scheduleEndMinute'] ?? 1439,
    };

    if (index >= 0) {
      alarms[index] = updatedAlarm;
    } else {
      alarms.add(updatedAlarm);
    }

    await saveAlarms();

    if (!mounted) return;
    setState(() {});
  }

  Future<List<Map<String, dynamic>>> loadAlarmHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(alarmHistoryStorageKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> openAlarmLibrary() async {
    final history = await loadAlarmHistory();
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => AlarmHistoryScreen(
          alarms: alarms
              .map((item) => Map<String, dynamic>.from(item))
              .toList(),
          history: history,
          onClearHistory: () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove(alarmHistoryStorageKey);
          },
          onToggleFavorite: (alarm) async {
            final index = alarms.indexWhere(
              (item) =>
                  item['name']?.toString() == alarm['name']?.toString() &&
                  item['latitude']?.toString() ==
                      alarm['latitude']?.toString() &&
                  item['longitude']?.toString() ==
                      alarm['longitude']?.toString(),
            );
            if (index < 0) return;
            alarms[index]['favorite'] = alarms[index]['favorite'] != true;
            await saveAlarms();
            if (mounted) setState(() {});
          },
          onReAdd: quickReAddAlarm,
          onOpenMap: (alarm) {
            final index = alarms.indexWhere(
              (item) =>
                  item['name']?.toString() == alarm['name']?.toString() &&
                  item['latitude']?.toString() ==
                      alarm['latitude']?.toString() &&
                  item['longitude']?.toString() ==
                      alarm['longitude']?.toString(),
            );
            if (index >= 0) openMap(alarms[index]);
          },
        ),
      ),
    );
    await loadAlarms();
  }

  Future<void> openFeatureCenter() async {
    final history = await loadAlarmHistory();
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => FeatureCenterScreen(
          alarms: alarms
              .map((item) => Map<String, dynamic>.from(item))
              .toList(),
          history: history,
          onToggleFavorite: (alarm) async {
            final index = alarms.indexWhere(
              (item) =>
                  item['name']?.toString() == alarm['name']?.toString() &&
                  item['latitude']?.toString() ==
                      alarm['latitude']?.toString() &&
                  item['longitude']?.toString() ==
                      alarm['longitude']?.toString(),
            );
            if (index < 0) return;
            alarms[index]['favorite'] = alarms[index]['favorite'] != true;
            await saveAlarms();
            if (mounted) setState(() {});
          },
          onUseFavorite: quickReAddAlarm,
          onClearHistory: () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove(alarmHistoryStorageKey);
          },
        ),
      ),
    );
    await loadAlarms();
  }

  Future<void> quickReAddAlarm(Map<String, dynamic> historyItem) async {
    final seed = <String, dynamic>{
      'name': historyItem['name']?.toString() ?? 'GeoAlarm',
      'latitude': historyItem['latitude'],
      'longitude': historyItem['longitude'],
      'radius': historyItem['radius'] ?? 100,
      'onArrival': historyItem['onArrival'] == true,
      'enabled': true,
      'triggered': false,
      'wasInside': false,
      'favorite': false,
      'scheduleEnabled': false,
      'repeatDaily': false,
      'repeatDays': [1, 2, 3, 4, 5, 6, 7],
      'scheduleStartMinute': 0,
      'scheduleEndMinute': 1439,
    };

    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => AddAlarmScreen(existingAlarm: seed),
      ),
    );
    if (result == null) return;

    result['enabled'] = true;
    result['triggered'] = false;
    result['wasInside'] = false;
    result['favorite'] = false;
    result.putIfAbsent('scheduleEnabled', () => false);
    result.putIfAbsent('repeatDaily', () => false);
    result.putIfAbsent('repeatDays', () => [1, 2, 3, 4, 5, 6, 7]);
    result.putIfAbsent('scheduleStartMinute', () => 0);
    result.putIfAbsent('scheduleEndMinute', () => 1439);
    alarms.add(result);
    await saveAlarms();
    await loadAlarms();
  }

  Future<void> toggleFavorite(Map<String, dynamic> alarm) async {
    final index = alarms.indexOf(alarm);
    if (index < 0) return;
    alarms[index]['favorite'] = alarms[index]['favorite'] != true;
    await saveAlarms();
    if (mounted) setState(() {});
  }

  Future<void> configureSchedule(Map<String, dynamic> alarm) async {
    bool scheduleEnabled = alarm['scheduleEnabled'] == true;
    bool repeatDaily = alarm['repeatDaily'] == true;
    final selectedDays = _repeatDaysFor(alarm).toSet();
    TimeOfDay startTime = TimeOfDay(
      hour: ((alarm['scheduleStartMinute'] as num?)?.toInt() ?? 0) ~/ 60,
      minute: ((alarm['scheduleStartMinute'] as num?)?.toInt() ?? 0) % 60,
    );
    final endMinute = (alarm['scheduleEndMinute'] as num?)?.toInt() ?? 1439;
    TimeOfDay endTime = TimeOfDay(
      hour: endMinute ~/ 60,
      minute: endMinute % 60,
    );
    const dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Schedule & repeat'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Limit monitoring hours'),
                    subtitle: const Text('Only trigger within the time window'),
                    value: scheduleEnabled,
                    onChanged: (value) =>
                        setDialogState(() => scheduleEnabled = value),
                  ),
                  if (scheduleEnabled) ...[
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: startTime,
                              );
                              if (picked != null) {
                                setDialogState(() => startTime = picked);
                              }
                            },
                            icon: const Icon(Icons.play_arrow),
                            label: Text('From ${startTime.format(context)}'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: endTime,
                              );
                              if (picked != null) {
                                setDialogState(() => endTime = picked);
                              }
                            },
                            icon: const Icon(Icons.stop),
                            label: Text('Until ${endTime.format(context)}'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  const Divider(),
                  const Text(
                    'Active days',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: List.generate(7, (index) {
                      final day = index + 1;
                      final selected = selectedDays.contains(day);
                      return FilterChip(
                        label: Text(dayLabels[index]),
                        selected: selected,
                        onSelected: (value) => setDialogState(() {
                          if (value) {
                            selectedDays.add(day);
                          } else {
                            selectedDays.remove(day);
                          }
                        }),
                      );
                    }),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Repeat on selected days'),
                    subtitle: const Text(
                      'Automatically re-arm after a trigger on a later selected day',
                    ),
                    value: repeatDaily,
                    onChanged: (value) =>
                        setDialogState(() => repeatDaily = value),
                  ),
                  if (selectedDays.isEmpty)
                    const Text(
                      'Select at least one active day.',
                      style: TextStyle(color: Colors.red),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: selectedDays.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: const Text('SAVE SCHEDULE'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;
    alarm['scheduleEnabled'] = scheduleEnabled;
    alarm['repeatDaily'] = repeatDaily;
    alarm['repeatDays'] = (selectedDays.toList()..sort());
    alarm['scheduleStartMinute'] = startTime.hour * 60 + startTime.minute;
    alarm['scheduleEndMinute'] = endTime.hour * 60 + endTime.minute;
    await saveAlarms();
    if (mounted) setState(() {});
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
                IconButton(
                  tooltip: alarm['favorite'] == true
                      ? 'Remove from favorites'
                      : 'Add to favorites',
                  onPressed: () => toggleFavorite(alarm),
                  icon: Icon(
                    alarm['favorite'] == true
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: alarm['favorite'] == true ? Colors.pink : null,
                  ),
                ),
                const SizedBox(width: 4),
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
            if (alarm['lastTriggeredAt'] is num) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.history, size: 17),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Last triggered: ${DateTime.fromMillisecondsSinceEpoch((alarm['lastTriggeredAt'] as num).toInt()).toLocal()}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
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
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => configureSchedule(alarm),
                icon: const Icon(Icons.schedule),
                label: Text(
                  alarm['scheduleEnabled'] == true ||
                          alarm['repeatDaily'] == true
                      ? 'EDIT SCHEDULE & REPEAT'
                      : 'SCHEDULE & REPEAT',
                ),
              ),
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
            tooltip: 'Favorites & history',
            onPressed: openAlarmLibrary,
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: 'Feature center',
            onPressed: openFeatureCenter,
            icon: const Icon(Icons.tune),
          ),
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
