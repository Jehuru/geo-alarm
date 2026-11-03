import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'route_service.dart';

class AddAlarmScreen extends StatefulWidget {
  final Map<String, dynamic>? existingAlarm;

  const AddAlarmScreen({super.key, this.existingAlarm});

  @override
  State<AddAlarmScreen> createState() => _AddAlarmScreenState();
}

class _AddAlarmScreenState extends State<AddAlarmScreen> {
  final locationController = TextEditingController();

  bool onArrival = true;
  double radius = 100;

  bool gettingLocation = false;
  bool searching = false;

  PlaceResult? selectedPlace;

  @override
  void initState() {
    super.initState();

    final alarm = widget.existingAlarm;

    if (alarm != null) {
      final savedLocationName = alarm['locationName']?.toString();

      final savedLocation = alarm['location']?.toString() ?? '';

      locationController.text = savedLocationName?.isNotEmpty == true
          ? savedLocationName!
          : savedLocation;

      onArrival = alarm['onArrival'] == true;

      radius = double.tryParse('${alarm['radius']}') ?? 100;

      final parts = savedLocation.split(',');

      if (parts.length >= 2) {
        final latitude = double.tryParse(parts[0].trim());

        final longitude = double.tryParse(parts[1].trim());

        if (latitude != null && longitude != null) {
          selectedPlace = PlaceResult(
            name: savedLocationName ?? 'Saved location',
            location: LatLng(latitude, longitude),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    locationController.dispose();
    super.dispose();
  }

  Future<void> searchLocation() async {
    final query = locationController.text.trim();

    if (query.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a location to search.')),
      );

      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      searching = true;
    });

    try {
      final results = await RouteService.searchPlace(query);

      if (!mounted) {
        return;
      }

      if (results.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No location found. Try a more specific name.'),
          ),
        );

        return;
      }

      if (results.length == 1) {
        selectPlace(results.first);
        return;
      }

      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Select Location',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ...results.map((place) {
                    return ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.location_on),
                      ),
                      title: Text(
                        place.name,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        selectPlace(place);

                        Navigator.pop(sheetContext);
                      },
                    );
                  }),
                ],
              ),
            ),
          );
        },
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Location search failed: $e')));
    } finally {
      if (mounted) {
        setState(() {
          searching = false;
        });
      }
    }
  }

  void selectPlace(PlaceResult place) {
    setState(() {
      selectedPlace = place;

      locationController.text = place.name;
    });
  }

  Future<void> useCurrentLocation() async {
    setState(() {
      gettingLocation = true;
    });

    try {
      bool enabled = await Geolocator.isLocationServiceEnabled();

      if (!enabled) {
        await Geolocator.openLocationSettings();

        enabled = await Geolocator.isLocationServiceEnabled();

        if (!enabled) {
          return;
        }
      }

      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission is required.')),
          );
        }

        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final place = PlaceResult(
        name: 'My Current Location',
        location: LatLng(position.latitude, position.longitude),
      );

      setState(() {
        selectedPlace = place;
        locationController.text = place.name;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not get location: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          gettingLocation = false;
        });
      }
    }
  }

  void saveAlarm() {
    if (selectedPlace == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Search for and select a location first.'),
        ),
      );

      return;
    }

    final place = selectedPlace!;

    final latitude = place.location.latitude;

    final longitude = place.location.longitude;

    final locationName = place.name;

    Navigator.pop(context, {
      // Alarm name is automatically
      // the selected location.
      'name': locationName,

      // Existing GPS alarm engine
      // uses this coordinate string.
      'location': '$latitude, $longitude',

      // Human-readable location.
      'locationName': locationName,

      'latitude': latitude,
      'longitude': longitude,

      'onArrival': onArrival,

      'radius': radius.round(),

      'triggered': false,
      'wasInside': false,
    });
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existingAlarm != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit Location Alarm' : 'Add Location Alarm'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Choose Destination',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),

          const SizedBox(height: 6),

          Text(
            'Search for the place where you want GeoAlarm to alert you.',
            style: TextStyle(color: Colors.grey.shade600),
          ),

          const SizedBox(height: 18),

          TextField(
            controller: locationController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => searchLocation(),
            decoration: InputDecoration(
              labelText: 'Search destination',
              hintText: 'e.g. Kenyatta University',
              prefixIcon: const Icon(Icons.location_on),
              suffixIcon: searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      onPressed: searchLocation,
                      icon: const Icon(Icons.search),
                    ),
              border: const OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 10),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: searching ? null : searchLocation,
              icon: const Icon(Icons.search),
              label: Text(searching ? 'SEARCHING...' : 'SEARCH LOCATION'),
            ),
          ),

          const SizedBox(height: 10),

          OutlinedButton.icon(
            onPressed: gettingLocation ? null : useCurrentLocation,
            icon: gettingLocation
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location),
            label: Text(
              gettingLocation
                  ? 'Getting location...'
                  : 'Use My Current Location',
            ),
          ),

          if (selectedPlace != null) ...[
            const SizedBox(height: 18),

            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Destination selected',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            selectedPlace!.name,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 28),

          const Text(
            'Trigger Alarm',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),

          const SizedBox(height: 10),

          SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(
                value: true,
                icon: Icon(Icons.location_on),
                label: Text('I arrive'),
              ),
              ButtonSegment<bool>(
                value: false,
                icon: Icon(Icons.logout),
                label: Text('I leave'),
              ),
            ],
            selected: {onArrival},
            onSelectionChanged: (selection) {
              setState(() {
                onArrival = selection.first;
              });
            },
          ),

          const SizedBox(height: 28),

          Row(
            children: [
              const Expanded(
                child: Text(
                  'Alarm radius',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                '${radius.round()} m',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),

          Slider(
            min: 25,
            max: 1000,
            divisions: 39,
            value: radius,
            label: '${radius.round()} m',
            onChanged: (value) {
              setState(() {
                radius = value;
              });
            },
          ),

          Text(
            'GeoAlarm will alert you when you enter or leave this radius.',
            style: TextStyle(color: Colors.grey.shade600),
          ),

          const SizedBox(height: 30),

          SizedBox(
            height: 54,
            child: FilledButton.icon(
              onPressed: selectedPlace == null ? null : saveAlarm,
              icon: const Icon(Icons.add_alert),
              label: Text(editing ? 'UPDATE ALARM' : 'CREATE ALARM'),
            ),
          ),
        ],
      ),
    );
  }
}
