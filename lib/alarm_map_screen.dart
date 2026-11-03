import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'route_service.dart';

class AlarmMapScreen extends StatefulWidget {
  final String alarmName;
  final double destinationLatitude;
  final double destinationLongitude;
  final double radius;

  const AlarmMapScreen({
    super.key,
    required this.alarmName,
    required this.destinationLatitude,
    required this.destinationLongitude,
    required this.radius,
  });

  @override
  State<AlarmMapScreen> createState() => _AlarmMapScreenState();
}

class _AlarmMapScreenState extends State<AlarmMapScreen> {
  final MapController _mapController = MapController();

  StreamSubscription<Position>? _positionSubscription;

  Position? _currentPosition;

  RouteResult? _route;

  bool _loadingLocation = true;
  bool _loadingRoute = false;
  String? _errorMessage;

  DateTime? _lastRouteUpdate;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();

    _initialize();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    final permissionGranted = await _checkLocationPermission();

    if (!permissionGranted) {
      if (mounted) {
        setState(() {
          _loadingLocation = false;
          _errorMessage =
              'Location permission is required to monitor this alarm.';
        });
      }

      return;
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;

      setState(() {
        _currentPosition = position;
        _loadingLocation = false;
      });

      await _updateRoute();

      _startLocationTracking();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loadingLocation = false;
        _errorMessage = 'Unable to get your current location.';
      });
    }
  }

  Future<bool> _checkLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Location disabled'),
              content: const Text(
                'Please enable GPS/location services to use the live map.',
              ),
              actions: [
                TextButton(
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

  void _startLocationTracking() {
    _positionSubscription?.cancel();

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen(_handlePosition);
  }

  Future<void> _handlePosition(Position position) async {
    final previousPosition = _currentPosition;

    if (!mounted) return;

    setState(() {
      _currentPosition = position;
    });

    bool shouldUpdateRoute = false;

    if (previousPosition == null) {
      shouldUpdateRoute = true;
    } else {
      final movedDistance = Geolocator.distanceBetween(
        previousPosition.latitude,
        previousPosition.longitude,
        position.latitude,
        position.longitude,
      );

      final lastUpdate = _lastRouteUpdate;

      final timePassed =
          lastUpdate == null ||
          DateTime.now().difference(lastUpdate).inSeconds >= 30;

      if (movedDistance >= 100 || timePassed) {
        shouldUpdateRoute = true;
      }
    }

    if (shouldUpdateRoute) {
      await _updateRoute();
    }
  }

  Future<void> _updateRoute() async {
    final position = _currentPosition;

    if (position == null || _loadingRoute) {
      return;
    }

    if (mounted) {
      setState(() {
        _loadingRoute = true;
        _errorMessage = null;
      });
    }

    try {
      final route = await RouteService.getRoute(
        start: LatLng(position.latitude, position.longitude),
        destination: LatLng(
          widget.destinationLatitude,
          widget.destinationLongitude,
        ),
      );

      if (!mounted) return;

      setState(() {
        _route = route;
        _lastRouteUpdate = DateTime.now();
        _loadingRoute = false;
      });
      if (_mapReady) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _fitRoute();
        });
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loadingRoute = false;
        _errorMessage = 'Unable to calculate the road route.';
      });
    }
  }

  double? get _straightLineDistance {
    final position = _currentPosition;

    if (position == null) {
      return null;
    }

    return Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      widget.destinationLatitude,
      widget.destinationLongitude,
    );
  }

  String _formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.round()} m';
    }

    return '${(meters / 1000).toStringAsFixed(2)} km';
  }

  String _formatDuration(double seconds) {
    final minutes = (seconds / 60).round();

    if (minutes < 1) {
      return 'Less than 1 min';
    }

    if (minutes == 1) {
      return '1 min';
    }

    if (minutes < 60) {
      return '$minutes min';
    }

    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;

    if (remainingMinutes == 0) {
      return '$hours hr';
    }

    return '$hours hr $remainingMinutes min';
  }

  void _centerOnUser() {
    final position = _currentPosition;

    if (position == null) return;

    _mapController.move(LatLng(position.latitude, position.longitude), 15);
  }

  void _fitRoute() {
    if (!_mapReady) return;

    final routePoints = _route?.points ?? <LatLng>[];
    final points = routePoints.isNotEmpty
        ? routePoints
        : <LatLng>[
            if (_currentPosition != null)
              LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            LatLng(widget.destinationLatitude, widget.destinationLongitude),
          ];

    if (points.isEmpty) return;

    if (points.length == 1) {
      _mapController.move(points.first, 15);
      return;
    }

    final bounds = LatLngBounds.fromPoints(points);
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.fromLTRB(48, 190, 48, 135),
        maxZoom: 16,
      ),
    );
  }

  void _showLocationDetails() {
    final distance = _straightLineDistance;

    final routeDistance = _route?.distanceMeters;

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.alarmName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 18),
                if (routeDistance != null)
                  _infoRow(
                    Icons.route,
                    'Road distance',
                    _formatDistance(routeDistance),
                  ),
                if (_route != null)
                  _infoRow(
                    Icons.access_time,
                    'Estimated travel time',
                    _formatDuration(_route!.durationSeconds),
                  ),
                if (distance != null)
                  _infoRow(
                    Icons.straighten,
                    'Direct distance',
                    _formatDistance(distance),
                  ),
                _infoRow(
                  Icons.radio_button_checked,
                  'Alarm radius',
                  '${widget.radius.round()} m',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _infoRow(IconData icon, String title, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(icon, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Text(title, style: TextStyle(color: Colors.grey.shade700)),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildMap() {
    final currentPosition = _currentPosition;

    final currentPoint = currentPosition == null
        ? null
        : LatLng(currentPosition.latitude, currentPosition.longitude);

    final destinationPoint = LatLng(
      widget.destinationLatitude,
      widget.destinationLongitude,
    );

    final routePoints = _route?.points ?? [];

    final initialCenter = currentPoint ?? destinationPoint;

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        // Start with a valid coordinate, then fit the user and destination
        // together after the map has mounted.
        initialCenter: initialCenter,
        initialZoom: 12,
        minZoom: 3,
        maxZoom: 19,
        onMapReady: () {
          _mapReady = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fitRoute();
          });
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.geo_alarm',
        ),

        if (routePoints.isNotEmpty)
          PolylineLayer(
            polylines: [Polyline(points: routePoints, strokeWidth: 5)],
          ),

        CircleLayer(
          circles: [
            CircleMarker(
              point: destinationPoint,
              radius: widget.radius,
              useRadiusInMeter: true,
              borderStrokeWidth: 3,
              color: Colors.indigo.withValues(alpha: 0.12),
              borderColor: Colors.indigo,
            ),
          ],
        ),

        MarkerLayer(
          markers: [
            Marker(
              point: destinationPoint,
              width: 55,
              height: 55,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.indigo,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [BoxShadow(blurRadius: 8, spreadRadius: 1)],
                ),
                child: const Icon(
                  Icons.location_on,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
            if (currentPoint != null)
              Marker(
                point: currentPoint,
                width: 50,
                height: 50,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [
                      BoxShadow(blurRadius: 8, spreadRadius: 1),
                    ],
                  ),
                  child: const Icon(
                    Icons.navigation,
                    color: Colors.white,
                    size: 25,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildTopInfo() {
    final route = _route;
    final directDistance = _straightLineDistance;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Card(
          elevation: 5,
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.location_on, color: Colors.indigo),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.alarmName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 17,
                        ),
                      ),
                    ),
                    if (_loadingRoute)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _metric(
                        Icons.route,
                        'Road distance',
                        route == null
                            ? 'Calculating...'
                            : _formatDistance(route.distanceMeters),
                      ),
                    ),
                    Expanded(
                      child: _metric(
                        Icons.access_time,
                        'ETA',
                        route == null
                            ? '--'
                            : _formatDuration(route.durationSeconds),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (directDistance != null)
                  Text(
                    'Direct distance: ${_formatDistance(directDistance)}',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                  ),
                const SizedBox(height: 4),
                Text(
                  'Alarm radius: ${widget.radius.round()} m',
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metric(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 19),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final destination = LatLng(
      widget.destinationLatitude,
      widget.destinationLongitude,
    );

    return Scaffold(
      extendBodyBehindAppBar: false,
      appBar: AppBar(
        title: const Text(
          'Live Alarm Map',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Location details',
            onPressed: _showLocationDetails,
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            tooltip: 'Refresh route',
            onPressed: _loadingRoute ? null : _updateRoute,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loadingLocation
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 15),
                  Text('Getting your location...'),
                ],
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                // Keep the map as the full-screen base layer. All controls
                // are positioned above it so they cannot constrain the map.
                Positioned.fill(child: _buildMap()),

                Positioned(
                  top: 10,
                  left: 10,
                  right: 10,
                  child: SafeArea(bottom: false, child: _buildTopInfo()),
                ),

                if (_errorMessage != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 145,
                    child: Card(
                      color: Colors.red.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline, color: Colors.red),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                Positioned(
                  right: 12,
                  bottom: 86,
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FloatingActionButton.small(
                          heroTag: 'fit_route',
                          onPressed: _fitRoute,
                          tooltip: 'Show full route',
                          child: const Icon(Icons.fit_screen),
                        ),
                        const SizedBox(height: 8),
                        FloatingActionButton.small(
                          heroTag: 'center_user',
                          onPressed: _centerOnUser,
                          tooltip: 'Center on me',
                          child: const Icon(Icons.my_location),
                        ),
                      ],
                    ),
                  ),
                ),

                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 10,
                  child: SafeArea(
                    top: false,
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: () => _mapController.move(destination, 16),
                        icon: const Icon(Icons.location_on),
                        label: const Text('SHOW DESTINATION'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
