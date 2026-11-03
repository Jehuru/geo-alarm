import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'route_service.dart';

class JourneyScreen extends StatefulWidget {
  final LatLng startLocation;
  final LatLng destinationLocation;

  final String startName;
  final String destinationName;

  final RouteResult route;

  const JourneyScreen({
    super.key,
    required this.startLocation,
    required this.destinationLocation,
    required this.startName,
    required this.destinationName,
    required this.route,
  });

  @override
  State<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends State<JourneyScreen> {
  final MapController mapController = MapController();

  StreamSubscription<Position>? positionSubscription;

  Position? currentPosition;

  final List<LatLng> travelledPath = [];

  double remainingDistance = 0;
  double travelledDistance = 0;

  bool journeyStarted = false;
  bool arrived = false;
  bool offRouteAlertShown = false;
  double distanceFromRoute = 0;

  DateTime? journeyStartTime;

  Timer? clockTimer;

  @override
  void initState() {
    super.initState();

    remainingDistance = widget.route.distanceMeters;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      fitRouteOnMap();
    });

    startTracking();

    clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    positionSubscription?.cancel();
    clockTimer?.cancel();
    super.dispose();
  }

  Future<bool> checkPermission() async {
    final enabled = await Geolocator.isLocationServiceEnabled();

    if (!enabled) {
      showMessage('Please turn on GPS/location services.');
      return false;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      showMessage('Location permission is required.');
      return false;
    }

    return true;
  }

  Future<void> startTracking() async {
    final allowed = await checkPermission();

    if (!allowed) return;

    positionSubscription?.cancel();

    const settings = LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 5,
    );

    positionSubscription =
        Geolocator.getPositionStream(locationSettings: settings).listen(
          handlePosition,
          onError: (error) {
            debugPrint('Journey location error: $error');
          },
        );

    if (mounted) {
      setState(() {
        journeyStarted = true;
        journeyStartTime ??= DateTime.now();
      });
    }
  }

  Future<void> handlePosition(Position position) async {
    if (!mounted) return;

    final point = LatLng(position.latitude, position.longitude);

    if (currentPosition != null) {
      final addedDistance = Geolocator.distanceBetween(
        currentPosition!.latitude,
        currentPosition!.longitude,
        position.latitude,
        position.longitude,
      );

      // Ignore impossible GPS jumps.
      if (addedDistance < 500) {
        travelledDistance += addedDistance;
      }
    }

    currentPosition = position;

    // Compare the live GPS fix with the planned route and warn only once
    // until the user returns close to the route.
    if (widget.route.points.isNotEmpty) {
      var nearest = double.infinity;
      for (final routePoint in widget.route.points) {
        final distance = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          routePoint.latitude,
          routePoint.longitude,
        );
        if (distance < nearest) nearest = distance;
      }
      distanceFromRoute = nearest;
      if (nearest > 250 && !offRouteAlertShown) {
        offRouteAlertShown = true;
        showMessage('You are more than 250 m from the planned route.');
      } else if (nearest < 120) {
        offRouteAlertShown = false;
      }
    }

    if (travelledPath.isEmpty ||
        Geolocator.distanceBetween(
              travelledPath.last.latitude,
              travelledPath.last.longitude,
              point.latitude,
              point.longitude,
            ) >=
            5) {
      travelledPath.add(point);
    }

    final straightLineRemaining = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      widget.destinationLocation.latitude,
      widget.destinationLocation.longitude,
    );

    remainingDistance = straightLineRemaining;

    await saveProgress();

    if (straightLineRemaining <= 100 && !arrived) {
      await arrive();
      return;
    }

    mapController.move(point, 16);

    setState(() {});
  }

  Future<void> saveProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final journeys = prefs.getStringList('activeJourneys') ?? [];

      final updated = <String>[];

      for (final item in journeys) {
        try {
          final journey = jsonDecode(item) as Map<String, dynamic>;

          final sameDestination =
              journey['destinationName'] == widget.destinationName &&
              (journey['destinationLatitude'] as num?)?.toDouble() ==
                  widget.destinationLocation.latitude &&
              (journey['destinationLongitude'] as num?)?.toDouble() ==
                  widget.destinationLocation.longitude;

          if (sameDestination && journey['status'] == 'active') {
            journey['travelledDistance'] = travelledDistance;

            journey['remainingDistance'] = remainingDistance;

            journey['arrived'] = arrived;
            journey['status'] = arrived ? 'completed' : 'active';
          }

          updated.add(jsonEncode(journey));
        } catch (_) {
          updated.add(item);
        }
      }

      await prefs.setStringList('activeJourneys', updated);
    } catch (e) {
      debugPrint('Could not save journey progress: $e');
    }
  }

  Future<void> _recordJourneyHistory(String status) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('journeyHistory') ?? <String>[];
      final elapsedSeconds = journeyStartTime == null
          ? 0
          : DateTime.now().difference(journeyStartTime!).inSeconds;
      final entry = <String, dynamic>{
        'startName': widget.startName,
        'destinationName': widget.destinationName,
        'startLatitude': widget.startLocation.latitude,
        'startLongitude': widget.startLocation.longitude,
        'destinationLatitude': widget.destinationLocation.latitude,
        'destinationLongitude': widget.destinationLocation.longitude,
        'travelledDistance': travelledDistance,
        'plannedDistance': widget.route.distanceMeters,
        'durationSeconds': elapsedSeconds,
        'status': status,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      raw.insert(0, jsonEncode(entry));
      await prefs.setStringList('journeyHistory', raw.take(100).toList());
    } catch (error) {
      debugPrint('Could not record journey history: $error');
    }
  }

  Future<void> arrive() async {
    if (arrived) return;

    arrived = true;
    remainingDistance = 0;

    await saveProgress();
    await _recordJourneyHistory('completed');

    positionSubscription?.cancel();

    if (mounted) {
      setState(() {});
    }

    await showArrivalDialog();
  }

  Future<void> showArrivalDialog() async {
    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return AlertDialog(
          title: const Text('🎉 You have arrived!'),
          content: Text('You have reached ${widget.destinationName}.'),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future<void> endJourney() async {
    positionSubscription?.cancel();

    try {
      final prefs = await SharedPreferences.getInstance();

      await _recordJourneyHistory('ended');
      final journeys = prefs.getStringList('activeJourneys') ?? [];

      final updated = <String>[];

      for (final item in journeys) {
        try {
          final journey = jsonDecode(item) as Map<String, dynamic>;

          final sameJourney =
              journey['destinationName'] == widget.destinationName &&
              (journey['destinationLatitude'] as num?)?.toDouble() ==
                  widget.destinationLocation.latitude &&
              (journey['destinationLongitude'] as num?)?.toDouble() ==
                  widget.destinationLocation.longitude;

          if (sameJourney && journey['status'] == 'active') {
            journey['status'] = 'ended';
            journey['travelledDistance'] = travelledDistance;
            journey['remainingDistance'] = remainingDistance;
          }

          updated.add(jsonEncode(journey));
        } catch (_) {
          updated.add(item);
        }
      }

      await prefs.setStringList('activeJourneys', updated);
    } catch (_) {}

    if (mounted) {
      Navigator.pop(context);
    }
  }

  void fitRouteOnMap() {
    if (widget.route.points.isEmpty) return;

    final bounds = LatLngBounds.fromPoints(widget.route.points);

    mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(70)),
    );
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.round()} m';
    }

    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String formatTime() {
    if (journeyStartTime == null) {
      return '--';
    }

    final elapsed = DateTime.now().difference(journeyStartTime!);

    final minutes = elapsed.inMinutes;

    if (minutes < 1) {
      return '<1 min';
    }

    if (minutes < 60) {
      return '$minutes min';
    }

    final hours = minutes ~/ 60;
    final remaining = minutes % 60;

    if (remaining == 0) {
      return '$hours hr';
    }

    return '$hours hr $remaining min';
  }

  String formatEta() {
    if (journeyStartTime == null || travelledDistance < 50) {
      return 'Calculating';
    }
    final seconds = DateTime.now().difference(journeyStartTime!).inSeconds;
    if (seconds <= 0) return 'Calculating';
    final averageSpeed = travelledDistance / seconds;
    if (averageSpeed < 0.5) return 'Calculating';
    final minutes = (remainingDistance / averageSpeed / 60).round();
    if (minutes < 1) return '<1 min';
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final remainder = minutes % 60;
    return remainder == 0 ? '$hours hr' : '$hours hr $remainder min';
  }

  @override
  Widget build(BuildContext context) {
    final travelledPoints = List<LatLng>.from(travelledPath);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Journey'),
        actions: [
          IconButton(
            onPressed: fitRouteOnMap,
            icon: const Icon(Icons.zoom_out_map),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: widget.startLocation,
              initialZoom: 14,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.geo_alarm',
              ),

              PolylineLayer(
                polylines: [
                  Polyline(points: widget.route.points, strokeWidth: 5),

                  if (travelledPoints.length >= 2)
                    Polyline(points: travelledPoints, strokeWidth: 6),
                ],
              ),

              MarkerLayer(
                markers: [
                  Marker(
                    point: widget.startLocation,
                    width: 45,
                    height: 45,
                    child: const Icon(Icons.trip_origin, size: 38),
                  ),

                  Marker(
                    point: widget.destinationLocation,
                    width: 50,
                    height: 50,
                    child: const Icon(Icons.flag, size: 42),
                  ),

                  if (currentPosition != null)
                    Marker(
                      point: LatLng(
                        currentPosition!.latitude,
                        currentPosition!.longitude,
                      ),
                      width: 55,
                      height: 55,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(width: 3, color: Colors.white),
                        ),
                        child: const Icon(Icons.navigation, size: 40),
                      ),
                    ),
                ],
              ),
            ],
          ),

          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Card(
              elevation: 6,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.navigation),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.destinationName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    Row(
                      children: [
                        Expanded(
                          child: _JourneyInfo(
                            title: 'Remaining',
                            value: formatDistance(remainingDistance),
                          ),
                        ),
                        Expanded(
                          child: _JourneyInfo(
                            title: 'Travelled',
                            value: formatDistance(travelledDistance),
                          ),
                        ),
                        Expanded(
                          child: _JourneyInfo(
                            title: 'Time',
                            value: formatTime(),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    Row(
                      children: [
                        Expanded(
                          child: _JourneyInfo(
                            title: 'Estimated arrival',
                            value: formatEta(),
                          ),
                        ),
                        Expanded(
                          child: _JourneyInfo(
                            title: 'Route status',
                            value: distanceFromRoute > 250
                                ? 'Off route'
                                : 'On route',
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    if (arrived)
                      const Text(
                        '🎉 ARRIVED',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    else
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: OutlinedButton.icon(
                          onPressed: endJourney,
                          icon: const Icon(Icons.stop),
                          label: const Text('END JOURNEY'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          if (journeyStarted && !arrived)
            Positioned(
              top: 12,
              left: 12,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.gps_fixed, size: 18),
                      const SizedBox(width: 6),
                      const Text(
                        'LIVE GPS',
                        style: TextStyle(fontWeight: FontWeight.bold),
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
}

class _JourneyInfo extends StatelessWidget {
  final String title;
  final String value;

  const _JourneyInfo({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(title, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
