import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../theme/app_colors.dart';
import '../models/app_models.dart';
import '../providers/app_providers.dart';
import '../widgets/shimmer_widgets.dart';
import '../widgets/map_markers.dart';
import '../widgets/route_card.dart';
import '../widgets/stop_board_sheet.dart';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  LatLng _currentLocation = const LatLng(65.0121, 25.4651);
  bool _hasRealLocation = false;
  bool _isSelectingStart = false;
  final MapController _mapController = MapController();
  bool _showSearchPanel = true;

  bool _showBusStops = false;
  List<Map<String, dynamic>> _rawStops = [];
  List<Marker> _stopMarkers = [];
  bool _isFetchingStops = false;
  String _stopSearchQuery = '';
  final TextEditingController _stopSearchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _determinePosition();
    _stopSearchController.addListener(() {
      setState(() => _stopSearchQuery = _stopSearchController.text);
      _rebuildStopMarkers();
    });
  }

  @override
  void dispose() {
    _stopSearchController.dispose();
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(12),
      ),
    );
  }

  Future<void> _determinePosition() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      _showSnack(
        'Sijainti ei tuettu tällä alustalla, käytetään Oulun keskustaa.',
      );
      return;
    }

    bool serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showSnack('Sijaintipalvelut ovat pois päältä.');
      return;
    }

    geo.LocationPermission permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
      if (permission == geo.LocationPermission.denied) {
        _showSnack('Sijaintilupa evätty.');
        return;
      }
    }

    if (permission == geo.LocationPermission.deniedForever) {
      _showSnack('Sijaintilupa pysyvästi evätty.');
      return;
    }

    try {
      geo.Position position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
        ),
      );
      setState(() {
        _currentLocation = LatLng(position.latitude, position.longitude);
        _hasRealLocation = true;
      });
      _mapController.move(_currentLocation, 14.0);
    } catch (e) {
      _showSnack('Virhe sijainnin haussa: $e');
    }
  }

  void _resetToCurrentLocation() {
    ref.read(startLocationProvider.notifier).state = null;
    ref.read(departureTimeProvider.notifier).state = DateTime.now();
    _mapController.move(_currentLocation, 14.0);
    _triggerSearch();
  }

  void _swapLocations() {
    final start = ref.read(startLocationProvider);
    final dest = ref.read(destinationLocationProvider);
    ref.read(startLocationProvider.notifier).state = dest;
    ref.read(destinationLocationProvider.notifier).state = start;
    _triggerSearch();
  }

  void _triggerSearch() {
    final dest = ref.read(destinationLocationProvider);
    if (dest == null) return;

    FocusScope.of(context).unfocus();
    setState(() => _showSearchPanel = false);

    final start = ref.read(startLocationProvider);
    final time = ref.read(departureTimeProvider);
    final transTime = ref.read(minTransferTimeProvider);
    final speed = ref.read(walkSpeedProvider);

    double sLat = start?.lat ?? _currentLocation.latitude;
    double sLon = start?.lon ?? _currentLocation.longitude;

    ref
        .read(routeStateProvider.notifier)
        .searchRoute(
          sLat,
          sLon,
          dest.lat,
          dest.lon,
          time,
          transTime,
          speed,
          destPlace: dest,
        );
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  void _zoomToRoute(List<RouteOption> options, int index) {
    if (options.isEmpty) return;
    final allPoints = options[index].segments.expand((s) => s.points).toList();
    if (allPoints.isNotEmpty) {
      final bounds = LatLngBounds.fromPoints(allPoints);
      _mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(100)),
      );
    }
  }

  Future<void> _fetchNearbyStops() async {
    if (_isFetchingStops) return;
    _isFetchingStops = true;
    try {
      final camera = _mapController.camera;
      final bounds = camera.visibleBounds;
      final api = ref.read(transitServiceProvider);
      final stops = await api.fetchNearbyStops(
        bounds.south,
        bounds.west,
        bounds.north,
        bounds.east,
      );
      if (mounted) {
        setState(() {
          _rawStops = stops;
        });
        _rebuildStopMarkers();
      }
    } finally {
      _isFetchingStops = false;
    }
  }

  void _rebuildStopMarkers() {
    final query = _stopSearchQuery.toLowerCase();
    final filtered = query.isEmpty
        ? _rawStops
        : _rawStops
              .where((s) => (s['name'] as String).toLowerCase().contains(query))
              .toList();

    setState(() {
      _stopMarkers = filtered
          .map(
            (stop) => Marker(
              point: LatLng(
                (stop['lat'] as num).toDouble(),
                (stop['lon'] as num).toDouble(),
              ),
              width: 15,
              height: 15,
              child: GestureDetector(
                onTap: () => _showStopOptions(stop),
                child: StopDot(stop['name'] ?? ''),
              ),
            ),
          )
          .toList();
    });
  }

  void _showStopOptions(Map<String, dynamic> stop) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 4),
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.transfer_within_a_station, color: kStop),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      stop['name'] ?? '',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: kStop,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.schedule, color: kBus),
              title: const Text('Näytä aikataulu'),
              onTap: () {
                Navigator.pop(ctx);
                _openStopBoard(stop);
              },
            ),
            ListTile(
              leading: const Icon(Icons.trip_origin, color: kWalk),
              title: const Text('Aseta lähtöpisteeksi'),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(startLocationProvider.notifier).state = Place(
                  name: stop['name'],
                  lat: (stop['lat'] as num).toDouble(),
                  lon: (stop['lon'] as num).toDouble(),
                );
                _triggerSearch();
              },
            ),
            ListTile(
              leading: const Icon(Icons.location_on, color: kPrimary),
              title: const Text('Aseta määränpääksi'),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(destinationLocationProvider.notifier).state = Place(
                  name: stop['name'],
                  lat: (stop['lat'] as num).toDouble(),
                  lon: (stop['lon'] as num).toDouble(),
                );
                _triggerSearch();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _openStopBoard(Map<String, dynamic> stop) {
    final stopLat = (stop['lat'] as num).toDouble();
    final stopLon = (stop['lon'] as num).toDouble();
    final stopName = stop['name'] as String? ?? '';
    final key = dotenv.env['DIGITRANSIT_KEY'] ?? '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (ctx2, scrollController) => StopBoardSheet(
          stopId: stop['gtfsId'] ?? '',
          stopName: stopName,
          digitransitKey: key,
          formatTime: _formatTime,
          scrollController: scrollController,
          onSetAsStart: () {
            Navigator.pop(ctx);
            ref.read(startLocationProvider.notifier).state = Place(
              name: stopName,
              lat: stopLat,
              lon: stopLon,
            );
            _triggerSearch();
          },
          onSetAsDestination: () {
            Navigator.pop(ctx);
            ref.read(destinationLocationProvider.notifier).state = Place(
              name: stopName,
              lat: stopLat,
              lon: stopLon,
            );
            _triggerSearch();
          },
        ),
      ),
    );
  }

  void _shareRoute(RouteOption option) {
    final buf = StringBuffer();
    buf.writeln('🚌 Pohjoisen Reitit');
    buf.writeln('Lähde klo ${_formatTime(option.leaveHomeTime)}');
    for (final leg in option.busLegs) {
      buf.writeln(
        '→ Linja ${leg.busNumber}: ${leg.fromStop} → ${leg.toStop} (klo ${_formatTime(leg.departureTime)})',
      );
    }
    buf.writeln('Perillä klo ${_formatTime(option.arrivalTime)}');
    buf.writeln(
      'Matka-aika: ${option.arrivalTime.difference(option.leaveHomeTime).inMinutes} min',
    );
    Clipboard.setData(ClipboardData(text: buf.toString()));
    _showSnack('Reittitiedot kopioitu leikepöydälle!');
  }

  Future<void> _pickDepartureDateTime() async {
    final time = ref.read(departureTimeProvider);
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: time,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 30)),
    );
    if (pickedDate == null || !mounted) return;

    final TimeOfDay? pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: time.hour, minute: time.minute),
    );
    if (pickedTime == null) return;

    ref.read(departureTimeProvider.notifier).state = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );
    _triggerSearch();
  }

  Future<void> _showSettingsDialog() async {
    int tempTransferTime = ref.read(minTransferTimeProvider);
    double tempWalkSpeed = ref.read(walkSpeedProvider);

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Hakuasetukset'),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Minimivaihtoaika:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              DropdownButton<int>(
                value: tempTransferTime,
                isExpanded: true,
                borderRadius: BorderRadius.circular(12),
                items: const [
                  DropdownMenuItem(value: 90, child: Text('1.5 min')),
                  DropdownMenuItem(value: 120, child: Text('2 min')),
                  DropdownMenuItem(value: 180, child: Text('3 min')),
                  DropdownMenuItem(value: 300, child: Text('5 min')),
                  DropdownMenuItem(value: 600, child: Text('10 min')),
                ],
                onChanged: (val) {
                  if (val != null) setDialogState(() => tempTransferTime = val);
                },
              ),
              const SizedBox(height: 20),
              Text(
                'Kävelyvauhti: ${tempWalkSpeed.toStringAsFixed(1)} km/h',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Slider(
                value: tempWalkSpeed,
                min: 2.0,
                max: 10.0,
                divisions: 16,
                activeColor: kPrimary,
                label: '${tempWalkSpeed.toStringAsFixed(1)} km/h',
                onChanged: (val) => setDialogState(() => tempWalkSpeed = val),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Peruuta'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kPrimary),
              onPressed: () {
                ref.read(minTransferTimeProvider.notifier).state =
                    tempTransferTime;
                ref.read(walkSpeedProvider.notifier).state = tempWalkSpeed;
                Navigator.pop(context);

                if (ref.read(destinationLocationProvider) != null) {
                  _triggerSearch();
                }
              },
              child: const Text('Tallenna'),
            ),
          ],
        ),
      ),
    );
  }

  List<Marker> _buildRouteStopMarkers(RouteState state) {
    if (state.options.isEmpty) return [];
    final route = state.options[state.selectedIndex];
    final List<Marker> markers = [];
    for (final leg in route.busLegs) {
      if (leg.fromLat != null && leg.fromLon != null) {
        markers.add(
          Marker(
            point: LatLng(leg.fromLat!, leg.fromLon!),
            width: 22,
            height: 22,
            child: BoardingStopMarker(leg.fromStop),
          ),
        );
      }
      for (final stop in leg.intermediateStops) {
        markers.add(
          Marker(
            point: LatLng(stop.lat, stop.lon),
            width: 11,
            height: 11,
            child: IntermediateStopDot(stop.name),
          ),
        );
      }
      if (leg.toLat != null && leg.toLon != null) {
        markers.add(
          Marker(
            point: LatLng(leg.toLat!, leg.toLon!),
            width: 22,
            height: 22,
            child: AlightingStopMarker(leg.toStop),
          ),
        );
      }
    }
    return markers;
  }

  List<Marker> _buildLiveBusMarkers(
    LiveBusState liveState,
    RouteState routeState,
  ) {
    if (liveState.feed == null || !liveState.isActive) return [];

    final Set<String> activeRouteIds = {};
    final Set<String> activeBusNumbers = {};

    if (routeState.options.isNotEmpty) {
      for (var leg in routeState.options[routeState.selectedIndex].busLegs) {
        activeBusNumbers.add(leg.busNumber);
        String rId = leg.routeGtfsId;
        if (rId.contains(':')) rId = rId.split(':').last;
        if (rId.isNotEmpty) activeRouteIds.add(rId);
      }
    }

    List<Marker> markers = [];
    for (var entity in liveState.feed!.entity) {
      if (!entity.hasVehicle()) continue;
      final vehicle = entity.vehicle;
      if (!vehicle.hasPosition() || !vehicle.hasTrip()) continue;

      final routeId = vehicle.trip.routeId;
      final pos = vehicle.position;

      bool matches =
          routeState.options.isEmpty ||
          activeRouteIds.contains(routeId) ||
          activeBusNumbers.contains(routeId) ||
          activeBusNumbers.any(
            (busNum) =>
                routeId.endsWith(':$busNum') ||
                routeId.endsWith('_$busNum') ||
                routeId == busNum,
          );

      if (!matches) continue;

      String displayNumber = routeId;
      if (routeState.options.isNotEmpty) {
        for (var leg in routeState.options[routeState.selectedIndex].busLegs) {
          String rId = leg.routeGtfsId.contains(':')
              ? leg.routeGtfsId.split(':').last
              : leg.routeGtfsId;
          if (routeId == rId ||
              routeId == leg.busNumber ||
              routeId.endsWith(leg.busNumber)) {
            displayNumber = leg.busNumber;
            break;
          }
        }
      } else {
        if (routeId.contains(':')) displayNumber = routeId.split(':').last;
        if (routeId.contains('_')) displayNumber = routeId.split('_').last;
      }

      markers.add(
        Marker(
          point: LatLng(pos.latitude, pos.longitude),
          width: 42,
          height: 52,
          child: LiveBusMarker(displayNumber),
        ),
      );
    }
    return markers;
  }

  void _showFavoritesSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Consumer(
        builder: (context, ref, _) {
          final favs = ref.watch(favoritesProvider);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 4),
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Row(
                  children: [
                    Icon(Icons.star_rounded, color: kAccent),
                    SizedBox(width: 10),
                    Text(
                      'Suosikkireittisi',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: kPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),
              if (favs.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Ei tallennettuja reittejä.\nTallenna reitti tähti-painikkeella reittikortin oikeasta yläkulmasta.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: favs.length,
                    itemBuilder: (_, index) {
                      final fav = favs[index];
                      return ListTile(
                        leading: const Icon(Icons.star_rounded, color: kAccent),
                        title: Text(
                          fav.destinationName,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Row(
                          children: [
                            const Icon(
                              Icons.trip_origin,
                              size: 11,
                              color: kWalk,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                fav.startName ?? 'Nykyinen sijainti',
                                style: const TextStyle(fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(
                              Icons.arrow_forward,
                              size: 11,
                              color: Colors.grey,
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.location_on,
                              size: 11,
                              color: kPrimary,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                fav.destinationName,
                                style: const TextStyle(fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                          ),
                          onPressed: () => ref
                              .read(favoritesProvider.notifier)
                              .removeFavorite(index),
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          ref
                              .read(destinationLocationProvider.notifier)
                              .state = Place(
                            name: fav.destinationName,
                            lat: fav.destLat,
                            lon: fav.destLon,
                          );
                          if (fav.startLat != null) {
                            ref
                                .read(startLocationProvider.notifier)
                                .state = Place(
                              name: fav.startName ?? '',
                              lat: fav.startLat!,
                              lon: fav.startLon!,
                            );
                          }
                          _triggerSearch();
                        },
                      );
                    },
                  ),
                ),
              SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSearchPanel() {
    final start = ref.watch(startLocationProvider);
    final dest = ref.watch(destinationLocationProvider);
    final time = ref.watch(departureTimeProvider);
    final isLoading = ref.watch(routeStateProvider).isLoading;
    final favs = ref.watch(favoritesProvider);

    final now = DateTime.now();
    final bool isToday =
        time.year == now.year && time.month == now.month && time.day == now.day;
    final String timeLabel = isToday
        ? 'Tänään ${_formatTime(time)}'
        : '${_formatDate(time)} klo ${_formatTime(time)}';

    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
      child: _showSearchPanel
          ? Card(
              elevation: 6,
              shadowColor: Colors.black26,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 4, 6),
                    child: Row(
                      children: [
                        const Icon(Icons.trip_origin, color: kWalk, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Autocomplete<Place>(
                            initialValue: TextEditingValue(
                              text: start?.name ?? '',
                            ),
                            optionsBuilder: (textEditingValue) => ref
                                .read(transitServiceProvider)
                                .getAutocompleteSuggestions(
                                  textEditingValue.text,
                                ),
                            displayStringForOption: (option) => option.name,
                            onSelected: (option) {
                              ref.read(startLocationProvider.notifier).state =
                                  option;
                              final recent = ref.read(
                                recentSearchesProvider.notifier,
                              );
                              recent.state = [
                                option,
                                ...recent.state
                                    .where((o) => o.name != option.name)
                                    .take(4),
                              ];
                              _triggerSearch();
                            },
                            fieldViewBuilder:
                                (ctx, controller, focusNode, onFieldSubmitted) {
                                  if (!focusNode.hasFocus &&
                                      controller.text != (start?.name ?? '')) {
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          if (mounted && !focusNode.hasFocus) {
                                            controller.text = start?.name ?? '';
                                          }
                                        });
                                  }
                                  return TextField(
                                    controller: controller,
                                    focusNode: focusNode,
                                    style: const TextStyle(fontSize: 14),
                                    decoration: const InputDecoration(
                                      hintText: 'Lähtöpiste (tyhjä = GPS)',
                                      hintStyle: TextStyle(color: Colors.grey),
                                      border: InputBorder.none,
                                      isDense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  );
                                },
                            optionsViewBuilder: _buildAutocompleteOptions,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.my_location,
                            color: start == null ? kBus : Colors.grey,
                            size: 20,
                          ),
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Käytä nykyistä sijaintia',
                          onPressed: _resetToCurrentLocation,
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.map_outlined,
                            color: _isSelectingStart ? kWalk : Colors.grey,
                            size: 20,
                          ),
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            setState(
                              () => _isSelectingStart = !_isSelectingStart,
                            );
                            if (_isSelectingStart) {
                              _showSnack('Napauta kartalta lähtöpiste!');
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _swapLocations,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: kSurface,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.grey[300]!),
                            ),
                            child: const Icon(
                              Icons.swap_vert,
                              size: 16,
                              color: kBus,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Container(
                            height: 1,
                            color: const Color(0xFFEEEEEE),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 4, 10),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.location_on,
                          color: kPrimary,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Autocomplete<Place>(
                            initialValue: TextEditingValue(
                              text: dest?.name ?? '',
                            ),
                            optionsBuilder: (textEditingValue) => ref
                                .read(transitServiceProvider)
                                .getAutocompleteSuggestions(
                                  textEditingValue.text,
                                ),
                            displayStringForOption: (option) => option.name,
                            onSelected: (option) {
                              ref
                                      .read(
                                        destinationLocationProvider.notifier,
                                      )
                                      .state =
                                  option;
                              final recent = ref.read(
                                recentSearchesProvider.notifier,
                              );
                              recent.state = [
                                option,
                                ...recent.state
                                    .where((o) => o.name != option.name)
                                    .take(4),
                              ];
                              _triggerSearch();
                            },
                            fieldViewBuilder:
                                (ctx, controller, focusNode, onFieldSubmitted) {
                                  if (!focusNode.hasFocus &&
                                      controller.text != (dest?.name ?? '')) {
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          if (mounted && !focusNode.hasFocus) {
                                            controller.text = dest?.name ?? '';
                                          }
                                        });
                                  }
                                  return TextField(
                                    controller: controller,
                                    focusNode: focusNode,
                                    style: const TextStyle(fontSize: 14),
                                    decoration: const InputDecoration(
                                      hintText: 'Syötä kohde Oulussa...',
                                      hintStyle: TextStyle(color: Colors.grey),
                                      border: InputBorder.none,
                                      isDense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  );
                                },
                            optionsViewBuilder: _buildAutocompleteOptions,
                          ),
                        ),
                        isLoading
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: kPrimary,
                                  ),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(
                                  Icons.search,
                                  color: kPrimary,
                                  size: 22,
                                ),
                                visualDensity: VisualDensity.compact,
                                onPressed: _triggerSearch,
                              ),
                      ],
                    ),
                  ),
                  if (favs.isNotEmpty) ...[
                    const Divider(height: 1, color: Color(0xFFEEEEEE)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      child: GestureDetector(
                        onTap: _showFavoritesSheet,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: kAccent.withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: kAccent.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.star_rounded,
                                size: 16,
                                color: kAccent,
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'Suosikit',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF664400),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: kAccent,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '${favs.length}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF3D2B00),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: GestureDetector(
                      onTap: _pickDepartureDateTime,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: kSurface,
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(color: const Color(0xFFDDDDDD)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.schedule, size: 16, color: kBus),
                            const SizedBox(width: 6),
                            Text(
                              timeLabel,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: kBus,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.expand_more,
                              size: 16,
                              color: kBus,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildAutocompleteOptions(
    BuildContext context,
    AutocompleteOnSelected<Place> onSelected,
    Iterable<Place> options,
  ) {
    final recent = ref.watch(recentSearchesProvider);
    return Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: MediaQuery.of(context).size.width - 100,
          constraints: const BoxConstraints(maxHeight: 250),
          child: ListView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: options.length,
            itemBuilder: (ctx, i) {
              final option = options.elementAt(i);
              final isHistory = recent.any((r) => r.name == option.name);
              return ListTile(
                leading: Icon(
                  isHistory ? Icons.history : Icons.place,
                  color: Colors.grey,
                ),
                title: Text(option.name),
                subtitle: option.label != null
                    ? Text(option.label!, style: const TextStyle(fontSize: 11))
                    : null,
                onTap: () => onSelected(option),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildStopSearchOverlay() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.search, color: kStop, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _stopSearchController,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'Suodata pysäkkejä nimellä...',
                hintStyle: TextStyle(color: Colors.grey, fontSize: 13),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (_stopSearchQuery.isNotEmpty)
            GestureDetector(
              onTap: () {
                _stopSearchController.clear();
                setState(() => _stopSearchQuery = '');
                _rebuildStopMarkers();
              },
              child: const Icon(Icons.close, color: Colors.grey, size: 16),
            ),
          if (_stopMarkers.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: kStop.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${_stopMarkers.length}',
                style: const TextStyle(
                  color: kStop,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRouteSheet() {
    final state = ref.watch(routeStateProvider);
    final favs = ref.watch(favoritesProvider);
    final dest = ref.watch(destinationLocationProvider);
    final isFav =
        dest != null && favs.any((f) => f.destinationName == dest.name);

    final screenHeight = MediaQuery.of(context).size.height;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final double minVisiblePixels = 65.0 + bottomPadding;
    final double minSheetSize = (minVisiblePixels / screenHeight).clamp(
      0.1,
      0.3,
    );

    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.only(bottom: keyboardHeight),
      child: DraggableScrollableSheet(
        initialChildSize: 0.38,
        minChildSize: minSheetSize,
        maxChildSize: 0.72,
        snap: true,
        snapSizes: [minSheetSize, 0.38, 0.72],
        builder: (context, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 24,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: ListView(
              controller: scrollController,
              padding: EdgeInsets.zero,
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 4),
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 8, 8),
                  child: Row(
                    children: [
                      const Text(
                        'Reittivaihtoehdot',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF222222),
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: _showFavoritesSheet,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: favs.isNotEmpty
                                ? kAccent.withValues(alpha: 0.15)
                                : kSurface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: favs.isNotEmpty
                                  ? kAccent.withValues(alpha: 0.5)
                                  : Colors.transparent,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.star_rounded,
                                size: 16,
                                color: favs.isNotEmpty ? kAccent : Colors.grey,
                              ),
                              if (favs.isNotEmpty) ...[
                                const SizedBox(width: 4),
                                Text(
                                  '${favs.length}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF996600),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (state.isOffline)
                        Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.wifi_off,
                                size: 12,
                                color: Colors.orange,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Offline',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.orange,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (state.options.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: kPrimary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${state.options.length} kpl',
                            style: const TextStyle(
                              color: kPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (state.isLoading)
                  for (int i = 0; i < 3; i++) const ShimmerCard(),
                if (!state.isLoading)
                  for (int i = 0; i < state.options.length; i++)
                    RouteCard(
                      option: state.options[i],
                      isSelected: state.selectedIndex == i,
                      isFavorite: isFav,
                      isOfflineData: state.isOffline,
                      formatTime: _formatTime,
                      onTap: () {
                        ref.read(routeStateProvider.notifier).selectRoute(i);
                        _zoomToRoute(state.options, i);
                      },
                      onToggleFavorite: () {
                        if (dest != null) {
                          ref
                              .read(favoritesProvider.notifier)
                              .toggleFavorite(
                                dest,
                                ref.read(startLocationProvider),
                              );
                        }
                      },
                      onShare: () => _shareRoute(state.options[i]),
                    ),
                SizedBox(height: 24 + MediaQuery.of(context).padding.bottom),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final routeState = ref.watch(routeStateProvider);
    final liveState = ref.watch(liveBusProvider);
    final startLoc = ref.watch(startLocationProvider);
    final destLoc = ref.watch(destinationLocationProvider);

    final List<RouteSegment> currentSegments = routeState.options.isNotEmpty
        ? routeState.options[routeState.selectedIndex].segments
        : [];
    final List<Marker> routeStopMarkers = _buildRouteStopMarkers(routeState);
    final List<Marker> mapLiveMarkers = _buildLiveBusMarkers(
      liveState,
      routeState,
    );

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        toolbarHeight: 52,
        backgroundColor: kPrimary,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: const [
            Icon(Icons.directions_bus_filled, size: 22, color: Colors.white),
            SizedBox(width: 8),
            Text(
              'Pohjoisen Reitit',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 20,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.transfer_within_a_station,
              color: _showBusStops ? Colors.yellowAccent : Colors.white,
            ),
            tooltip: _showBusStops ? 'Piilota pysäkit' : 'Näytä pysäkit',
            onPressed: () async {
              setState(() => _showBusStops = !_showBusStops);
              if (_showBusStops) {
                await _fetchNearbyStops();
              } else {
                _stopSearchController.clear();
                setState(() {
                  _rawStops = [];
                  _stopMarkers = [];
                  _stopSearchQuery = '';
                });
              }
            },
          ),
          IconButton(
            icon: Icon(
              _showSearchPanel ? Icons.search_off : Icons.search,
              color: Colors.white,
            ),
            tooltip: _showSearchPanel ? 'Piilota haku' : 'Näytä haku',
            onPressed: () =>
                setState(() => _showSearchPanel = !_showSearchPanel),
          ),
          IconButton(
            icon: const Icon(Icons.tune, color: Colors.white),
            tooltip: 'Asetukset',
            onPressed: _showSettingsDialog, // Asetusvalikko avautuu nyt tästä
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentLocation,
              initialZoom: 13.0,
              onTap: (tapPosition, point) {
                if (_isSelectingStart) {
                  setState(() => _isSelectingStart = false);
                  ref.read(startLocationProvider.notifier).state = Place(
                    name: '📍 Valittu kartalta',
                    lat: point.latitude,
                    lon: point.longitude,
                  );
                  _showSnack('Lähtöpiste asetettu kartalta!');
                  _triggerSearch();
                }
              },
              onMapEvent: (event) {
                if (_showBusStops && event is MapEventMoveEnd) {
                  _fetchNearbyStops();
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.pohjoisen_reitit',
              ),
              PolylineLayer(
                polylines: [
                  for (final segment in currentSegments)
                    Polyline(
                      points: segment.points,
                      strokeWidth: segment.isWalk ? 3.5 : 5.5,
                      color: segment.isWalk
                          ? kWalk.withValues(alpha: 0.8)
                          : kBus.withValues(alpha: 0.85),
                      pattern: segment.isWalk
                          ? StrokePattern.dashed(segments: [10, 7])
                          : const StrokePattern.solid(),
                    ),
                ],
              ),
              if (_showBusStops && _stopMarkers.isNotEmpty)
                MarkerLayer(markers: _stopMarkers),
              if (routeStopMarkers.isNotEmpty)
                MarkerLayer(markers: routeStopMarkers),
              if (liveState.isActive && mapLiveMarkers.isNotEmpty)
                MarkerLayer(markers: mapLiveMarkers),
              MarkerLayer(
                markers: [
                  Marker(
                    point: _currentLocation,
                    width: 42,
                    height: 42,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _hasRealLocation ? kBus : Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [
                          BoxShadow(
                            color: (_hasRealLocation ? kBus : Colors.green)
                                .withValues(alpha: 0.35),
                            blurRadius: 8,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Icon(
                        _hasRealLocation
                            ? Icons.person_pin_circle
                            : Icons.location_searching,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  if (startLoc != null)
                    Marker(
                      point: LatLng(startLoc.lat, startLoc.lon),
                      width: 42,
                      height: 42,
                      child: const StartMarker(),
                    ),
                  if (destLoc != null)
                    Marker(
                      point: LatLng(destLoc.lat, destLoc.lon),
                      width: 42,
                      height: 52,
                      child: const DestinationMarker(),
                    ),
                ],
              ),
            ],
          ),
          Positioned(top: 12, left: 12, right: 12, child: _buildSearchPanel()),
          if (_showBusStops)
            Positioned(
              bottom: (routeState.options.isNotEmpty || routeState.isLoading)
                  ? 270
                  : 80,
              left: 16,
              right: 80,
              child: _buildStopSearchOverlay(),
            ),
          if (_isSelectingStart)
            Positioned(
              top: _showSearchPanel ? 210 : 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: kWalk,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: kWalk.withValues(alpha: 0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.touch_app, color: Colors.white, size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Napauta kartalta lähtöpiste',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (routeState.options.isNotEmpty || routeState.isLoading)
            _buildRouteSheet(),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 40.0),
        child: FloatingActionButton.extended(
          onPressed: () => ref.read(liveBusProvider.notifier).toggleTracking(),
          backgroundColor: liveState.isActive ? kDelayed : kLiveBus,
          foregroundColor: liveState.isActive ? Colors.white : kPrimaryDark,
          elevation: 4,
          icon: Icon(
            liveState.isActive ? Icons.stop_circle : Icons.satellite_alt,
          ),
          label: Text(liveState.isActive ? 'Lopeta Live' : 'Aloita Live'),
        ),
      ),
    );
  }
}
