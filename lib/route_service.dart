import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class RouteResult {
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;

  RouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  double get distanceKm => distanceMeters / 1000;

  int get durationMinutes => (durationSeconds / 60).round();
}

class PlaceResult {
  final String name;
  final LatLng location;

  PlaceResult({required this.name, required this.location});
}

class RouteService {
  static const String _nominatimUrl =
      'https://nominatim.openstreetmap.org/search';

  static const String _osrmUrl =
      'https://router.project-osrm.org/route/v1/driving';

  static Future<List<PlaceResult>> searchPlace(String query) async {
    final uri = Uri.parse(_nominatimUrl).replace(
      queryParameters: {
        'q': query,
        'format': 'jsonv2',
        'limit': '5',
        'countrycodes': 'ke',
      },
    );

    final response = await http.get(
      uri,
      headers: {
        'User-Agent': 'GeoAlarm/1.0 (GeoAlarm Flutter App)',
        'Accept': 'application/json',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Location search failed: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);

    if (data is! List) {
      return [];
    }

    return data
        .whereType<Map>()
        .map((item) {
          final latitude = double.tryParse('${item['lat']}');

          final longitude = double.tryParse('${item['lon']}');

          if (latitude == null || longitude == null) {
            return null;
          }

          return PlaceResult(
            name: item['display_name']?.toString() ?? query,
            location: LatLng(latitude, longitude),
          );
        })
        .whereType<PlaceResult>()
        .toList();
  }

  static Future<RouteResult> getRoute({
    required LatLng start,
    required LatLng destination,
  }) async {
    final coordinates =
        '${start.longitude},${start.latitude};'
        '${destination.longitude},${destination.latitude}';

    final uri = Uri.parse('$_osrmUrl/$coordinates').replace(
      queryParameters: {
        'overview': 'full',
        'geometries': 'geojson',
        'steps': 'false',
      },
    );

    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception('Route request failed: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);

    if (data['code'] != 'Ok') {
      throw Exception('No road route could be found.');
    }

    final routes = data['routes'];

    if (routes is! List || routes.isEmpty) {
      throw Exception('No route found.');
    }

    final route = routes.first;

    final distance = (route['distance'] as num).toDouble();

    final duration = (route['duration'] as num).toDouble();

    final geometry = route['geometry'];

    if (geometry == null || geometry['coordinates'] == null) {
      throw Exception('Route geometry is unavailable.');
    }

    final coordinatesList = geometry['coordinates'] as List;

    final points = coordinatesList
        .whereType<List>()
        .where((point) => point.length >= 2)
        .map(
          (point) => LatLng(
            (point[1] as num).toDouble(),
            (point[0] as num).toDouble(),
          ),
        )
        .toList();

    return RouteResult(
      points: points,
      distanceMeters: distance,
      durationSeconds: duration,
    );
  }
}
