import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import '../models/app_models.dart';
import 'realtime_utils.dart';

class TransitService {
  final String digitransitKey;
  final String walttiClientId;
  final String walttiClientSecret;

  /// Jaettu client kierrättää yhteyksiä – tärkeää, koska live-sijainteja
  /// pollataan muutaman sekunnin välein.
  final http.Client _client;

  static final Uri _routingUrl = Uri.parse(
    'https://api.digitransit.fi/routing/v2/waltti/gtfs/v1',
  );
  static const String _geocodingHost = 'api.digitransit.fi';
  static const String _gtfsRtBase =
      'https://data.waltti.fi/oulu/api/gtfsrealtime/v1.0/feed';

  /// Oulun seudun rajaus paikkahaulle.
  static const String _minLat = '64.7';
  static const String _maxLat = '65.45';
  static const String _minLon = '24.9';
  static const String _maxLon = '26.5';

  static const Duration _requestTimeout = Duration(seconds: 12);

  /// Live-feedit pollataan tiheästi, joten jumittunut pyyntö ei saa
  /// tukkia seuraavia kierroksia pitkäksi aikaa.
  static const Duration _liveFeedTimeout = Duration(seconds: 5);

  TransitService({
    required this.digitransitKey,
    required this.walttiClientId,
    required this.walttiClientSecret,
    http.Client? client,
  }) : _client = client ?? http.Client();

  void dispose() {
    _client.close();
  }

  Future<List<Place>> getAutocompleteSuggestions(String query) async {
    final String text = query.trim();
    if (text.length < 2) return [];
    try {
      // Uri.https enkoodaa käyttäjän syötteen (välilyönnit, &, # jne.),
      // jotta erikoismerkit eivät riko kyselyä.
      final uri = Uri.https(_geocodingHost, '/geocoding/v1/autocomplete', {
        'text': text,
        'boundary.rect.min_lat': _minLat,
        'boundary.rect.max_lat': _maxLat,
        'boundary.rect.min_lon': _minLon,
        'boundary.rect.max_lon': _maxLon,
      });
      final response = await _client
          .get(uri, headers: {'digitransit-subscription-key': digitransitKey})
          .timeout(_requestTimeout);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final features = data['features'] as List<dynamic>? ?? [];
        return features
            .map(
              (f) => Place(
                name: f['properties']?['name'] ?? '',
                label: f['properties']?['label'],
                lat: (f['geometry']['coordinates'][1] as num).toDouble(),
                lon: (f['geometry']['coordinates'][0] as num).toDouble(),
              ),
            )
            .toList();
      }
      debugPrint('Autocomplete HTTP ${response.statusCode}');
    } catch (e) {
      debugPrint('Autocomplete error: $e');
    }
    return [];
  }

  Future<FeedMessage?> fetchLiveBuses() => _fetchGtfsRtFeed('vehicleposition');

  Future<FeedMessage?> fetchTripUpdates() => _fetchGtfsRtFeed('tripupdate');

  /// Palauttaa null virhetilanteessa – kutsuja päättää, miten vanhan
  /// datan kanssa toimitaan.
  Future<FeedMessage?> _fetchGtfsRtFeed(String feedName) async {
    final String encodedCredentials = base64Encode(
      utf8.encode('$walttiClientId:$walttiClientSecret'),
    );
    try {
      final response = await _client
          .get(
            Uri.parse('$_gtfsRtBase/$feedName'),
            headers: {'Authorization': 'Basic $encodedCredentials'},
          )
          .timeout(_liveFeedTimeout);
      if (response.statusCode == 200) {
        return FeedMessage.fromBuffer(response.bodyBytes);
      }
      debugPrint('GTFS-RT $feedName HTTP ${response.statusCode}');
    } catch (e) {
      debugPrint('GTFS-RT $feedName fetch error: $e');
    }
    return null;
  }

  /// Suorittaa GraphQL-kyselyn ja palauttaa vastauksen data-osan.
  /// Heittää poikkeuksen HTTP-virheestä tai aikakatkaisusta.
  Future<Map<String, dynamic>?> _runGraphQl(String query) async {
    final response = await _client
        .post(
          _routingUrl,
          headers: {
            'Content-Type': 'application/json',
            'digitransit-subscription-key': digitransitKey,
          },
          body: json.encode({'query': query}),
        )
        .timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw Exception('API Error: ${response.statusCode}');
    }
    final decoded = json.decode(response.body);
    return decoded['data'] as Map<String, dynamic>?;
  }

  Future<List<Map<String, dynamic>>> fetchNearbyStops(
    double s,
    double w,
    double n,
    double e,
  ) async {
    final String query =
        """
      {
        stopsByBbox(minLat: $s, minLon: $w, maxLat: $n, maxLon: $e) {
          gtfsId name lat lon
        }
      }
    """;
    try {
      final data = await _runGraphQl(query);
      final stops = data?['stopsByBbox'] as List<dynamic>?;
      if (stops != null) {
        return stops.map((st) => Map<String, dynamic>.from(st)).toList();
      }
    } catch (err) {
      debugPrint('Error fetching stops: $err');
    }
    return [];
  }

  Future<List<Map<String, dynamic>>?> fetchTripRoute(
    String tripId,
    String gtfsId,
  ) async {
    if (tripId.isEmpty) return null;

    final String query =
        """
    {
      trip(id: "$tripId") {
        stoptimes {
          stop {
            name
            gtfsId
            lat
            lon
          }
          scheduledDeparture
          realtimeDeparture
          realtimeState
          realtime
          serviceDay
        }
      }
    }
    """;

    try {
      final data = await _runGraphQl(query);
      final tripData = data?['trip'];

      if (tripData != null && tripData['stoptimes'] != null) {
        final stoptimes = tripData['stoptimes'] as List<dynamic>;
        return stoptimes.map((st) => Map<String, dynamic>.from(st)).toList();
      }
    } catch (e) {
      debugPrint('Error fetching full trip route: $e');
    }
    return null;
  }

  /// Pysäkin seuraavat lähdöt aikataulunäyttöä varten.
  /// Heittää poikkeuksen virhetilanteessa, jotta UI voi näyttää virheen
  /// ja tarjota uudelleenyrityksen.
  Future<List<StopTimeData>> fetchStopDepartures(String stopId) async {
    if (stopId.isEmpty) return [];
    final int startTimeSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final String query =
        """
    {
      stop(id: "$stopId") {
        stoptimesWithoutPatterns(startTime: $startTimeSec, timeRange: 7200, numberOfDepartures: 20) {
          scheduledDeparture realtimeDeparture realtimeState realtime serviceDay headsign
          trip { gtfsId route { shortName gtfsId } }
        }
      }
    }
    """;

    final data = await _runGraphQl(query);
    final stoptimes =
        data?['stop']?['stoptimesWithoutPatterns'] as List<dynamic>?;
    if (stoptimes == null) return [];
    return stoptimes
        .map((st) => _parseStopTime(st as Map<String, dynamic>))
        .whereType<StopTimeData>()
        .toList();
  }

  StopTimeData? _parseStopTime(Map<String, dynamic> st) {
    final String? busNumber = st['trip']?['route']?['shortName'];
    final int? scheduledDeparture = st['scheduledDeparture'];
    final int? serviceDay = st['serviceDay'];
    if (busNumber == null || scheduledDeparture == null || serviceDay == null) {
      return null;
    }
    final int? realtimeDeparture = st['realtimeDeparture'];
    return StopTimeData(
      scheduledEpochSec: serviceDay + scheduledDeparture,
      realtimeEpochSec: serviceDay + (realtimeDeparture ?? scheduledDeparture),
      realtimeState: st['realtimeState'] ?? 'SCHEDULED',
      isRealtime: st['realtime'] ?? false,
      busNumber: busNumber,
      headsign: st['headsign'],
      tripId: st['trip']?['gtfsId'] ?? '',
      routeGtfsId: st['trip']?['route']?['gtfsId'] ?? '',
    );
  }

  Future<List<RouteOption>> fetchRoutes(
    double startLat,
    double startLon,
    double destLat,
    double destLon,
    DateTime departureTime,
    int minTransferTime,
    double walkSpeedMS, {
    bool isFallback = false,
  }) async {
    final data = await _runGraphQl(
      _buildPlanQuery(
        startLat,
        startLon,
        destLat,
        destLon,
        departureTime,
        minTransferTime,
        walkSpeedMS,
        isFallback: isFallback,
      ),
    );

    final itineraries = data?['plan']?['itineraries'] as List<dynamic>?;
    if (itineraries == null || itineraries.isEmpty) {
      if (!isFallback) {
        // Ei reittejä lähitunneilta – etsitään seuraava lähtö vuorokauden
        // sisältä ja haetaan varsinaiset vaihtoehdot sen ympäriltä.
        return fetchRoutes(
          startLat,
          startLon,
          destLat,
          destLon,
          departureTime,
          minTransferTime,
          walkSpeedMS,
          isFallback: true,
        );
      }
      return [];
    }

    if (isFallback) {
      final nextTime = DateTime.fromMillisecondsSinceEpoch(
        itineraries[0]['startTime'],
      );
      return fetchRoutes(
        startLat,
        startLon,
        destLat,
        destLon,
        nextTime.subtract(const Duration(minutes: 10)),
        minTransferTime,
        walkSpeedMS,
      );
    }

    List<RouteOption> parsedOptions = [
      for (var itinerary in itineraries) _parseItinerary(itinerary),
    ];

    parsedOptions = await _expandWithTimetables(parsedOptions, departureTime);

    parsedOptions.sort((a, b) => a.leaveHomeTime.compareTo(b.leaveHomeTime));
    return parsedOptions;
  }

  String _buildPlanQuery(
    double startLat,
    double startLon,
    double destLat,
    double destLon,
    DateTime departureTime,
    int minTransferTime,
    double walkSpeedMS, {
    required bool isFallback,
  }) {
    final int searchWindow = isFallback ? 86400 : 10800;
    return """
    {
      plan(
        from: {lat: $startLat, lon: $startLon},
        to: {lat: $destLat, lon: $destLon},
        numItineraries: 10,
        searchWindow: $searchWindow,
        walkSpeed: ${walkSpeedMS.toStringAsFixed(2)},
        walkReluctance: 1.0,
        minTransferTime: $minTransferTime,
        date: "${departureTime.year}-${departureTime.month.toString().padLeft(2, '0')}-${departureTime.day.toString().padLeft(2, '0')}",
        time: "${departureTime.hour.toString().padLeft(2, '0')}:${departureTime.minute.toString().padLeft(2, '0')}:00",
        arriveBy: false
      ) {
        itineraries {
          startTime endTime
          legs {
            mode startTime endTime distance
            interlineWithPreviousLeg
            trip { gtfsId }
            route { shortName gtfsId alerts { alertHeaderText } }
            from { name lat lon stop { gtfsId } }
            to { name lat lon stop { gtfsId } }
            legGeometry { points }
            intermediateStops { name lat lon gtfsId }
          }
        }
      }
    }
    """;
  }

  RouteOption _parseItinerary(Map<String, dynamic> itinerary) {
    final DateTime leaveHome = DateTime.fromMillisecondsSinceEpoch(
      itinerary['startTime'],
    );
    final DateTime arrival = DateTime.fromMillisecondsSinceEpoch(
      itinerary['endTime'],
    );
    final List<RouteSegment> segments = [];
    final List<BusLeg> busLegs = [];
    final List<double> walkDistances = [];

    double currentWalk = 0.0;

    for (var leg in itinerary['legs']) {
      if (leg['mode'] == 'WALK') {
        currentWalk += (leg['distance'] as num).toDouble();
      }

      if (leg['mode'] == 'BUS') {
        walkDistances.add(currentWalk);
        currentWalk = 0.0;
        busLegs.add(_parseBusLeg(leg));
      }

      if (leg['legGeometry']?['points'] != null) {
        List<PointLatLng> result = PolylinePoints.decodePolyline(
          leg['legGeometry']['points'],
        );
        final legPoints = result
            .map((p) => LatLng(p.latitude, p.longitude))
            .toList();
        if (legPoints.isNotEmpty) {
          segments.add(
            RouteSegment(points: legPoints, isWalk: leg['mode'] == 'WALK'),
          );
        }
      }
    }

    walkDistances.add(currentWalk);

    return RouteOption(
      leaveHomeTime: leaveHome,
      arrivalTime: arrival,
      busLegs: busLegs,
      segments: segments,
      walkDistances: walkDistances,
    );
  }

  BusLeg _parseBusLeg(Map<String, dynamic> leg) {
    final String fromStopId = leg['from']?['stop']?['gtfsId'] ?? '';
    final String toStopId = leg['to']?['stop']?['gtfsId'] ?? '';
    final String tripId = leg['trip']?['gtfsId'] ?? '';
    final DateTime scheduledDep = DateTime.fromMillisecondsSinceEpoch(
      leg['startTime'],
    );
    final double? fromLat = (leg['from']?['lat'] as num?)?.toDouble();
    final double? fromLon = (leg['from']?['lon'] as num?)?.toDouble();
    final double? toLat = (leg['to']?['lat'] as num?)?.toDouble();
    final double? toLon = (leg['to']?['lon'] as num?)?.toDouble();

    final bool stayOnBus = leg['interlineWithPreviousLeg'] ?? false;

    final List<IntermediateStop> intermediateStops = [];
    final List<String> legStopIds = [fromStopId];
    final rawStops = leg['intermediateStops'] as List<dynamic>?;

    if (rawStops != null) {
      for (var s in rawStops) {
        if (s['lat'] != null && s['lon'] != null) {
          String? stopGtfsId = s['gtfsId'] as String?;
          if (stopGtfsId != null && stopGtfsId.isNotEmpty) {
            legStopIds.add(stopGtfsId);
          }
          intermediateStops.add(
            IntermediateStop(
              name: s['name'] ?? '',
              lat: (s['lat'] as num).toDouble(),
              lon: (s['lon'] as num).toDouble(),
              gtfsId: stopGtfsId,
            ),
          );
        }
      }
    }

    if (toStopId.isNotEmpty) {
      legStopIds.add(toStopId);
    }

    final List<AlertInfo> alerts = [];
    final rawAlerts = leg['route']?['alerts'] as List<dynamic>?;

    if (rawAlerts != null) {
      for (var a in rawAlerts) {
        final text = a['alertHeaderText'];
        if (text != null && text.toString().isNotEmpty) {
          alerts.add(AlertInfo(text: text.toString()));
        }
      }
    }

    return BusLeg(
      busNumber: leg['route']['shortName'] ?? 'Bussi',
      routeGtfsId: leg['route']['gtfsId'] ?? '',
      tripId: tripId,
      fromStop: leg['from']['name'] ?? 'Tuntematon pysäkki',
      fromStopId: fromStopId,
      toStopId: toStopId,
      legStopIds: legStopIds,
      fromLat: fromLat,
      fromLon: fromLon,
      toStop: leg['to']['name'] ?? 'Tuntematon pysäkki',
      toLat: toLat,
      toLon: toLon,
      departureTime: scheduledDep,
      arrivalTime: DateTime.fromMillisecondsSinceEpoch(leg['endTime']),
      realtimeDeparture: scheduledDep,
      realtimeState: 'SCHEDULED',
      isRealtime: false,
      stayOnBus: stayOnBus,
      intermediateStops: intermediateStops,
      alerts: alerts,
    );
  }

  /// Laajentaa reittivaihtoehdot ensimmäisen nousupysäkin aikataululla:
  /// samasta reittiketjusta luodaan vaihtoehto jokaiselle lähtövuorolle.
  /// Virhetilanteessa palautetaan alkuperäiset vaihtoehdot sellaisenaan.
  Future<List<RouteOption>> _expandWithTimetables(
    List<RouteOption> parsedOptions,
    DateTime departureTime,
  ) async {
    final Set<String> stopIdsToQuery = {};
    for (var opt in parsedOptions) {
      if (opt.busLegs.isNotEmpty && opt.busLegs.first.fromStopId.isNotEmpty) {
        stopIdsToQuery.add(opt.busLegs.first.fromStopId);
      }
    }
    if (stopIdsToQuery.isEmpty) return parsedOptions;

    String stopQueries = '';
    int i = 0;
    final startTimeSec = departureTime.millisecondsSinceEpoch ~/ 1000;

    for (String stopId in stopIdsToQuery) {
      stopQueries +=
          """
        stop$i: stop(id: "$stopId") {
          gtfsId
          stoptimesWithoutPatterns(startTime: $startTimeSec, timeRange: 7200, numberOfDepartures: 30) {
            scheduledDeparture realtimeDeparture realtimeState realtime serviceDay
            trip { gtfsId route { shortName } }
          }
        }
      """;
      i++;
    }

    try {
      final ttDataMap = await _runGraphQl('{ $stopQueries }');
      if (ttDataMap == null) return parsedOptions;

      final Map<String, List<StopTimeData>> timetableMap = {};

      ttDataMap.forEach((alias, stopData) {
        if (stopData == null || stopData['gtfsId'] == null) return;
        final String sId = stopData['gtfsId'];
        final stoptimes =
            stopData['stoptimesWithoutPatterns'] as List<dynamic>?;
        if (stoptimes == null) return;

        for (var st in stoptimes) {
          final parsed = _parseStopTime(st as Map<String, dynamic>);
          if (parsed == null) continue;
          timetableMap
              .putIfAbsent('${sId}_${parsed.busNumber}', () => [])
              .add(parsed);
        }
      });

      final List<RouteOption> expandedOptions = [];
      final Set<String> addedSignatures = {};

      for (var opt in parsedOptions) {
        if (opt.busLegs.isEmpty) {
          final String sig =
              'walk_only_${(opt.arrivalTime.millisecondsSinceEpoch / 600000).round()}';
          if (addedSignatures.add(sig)) {
            expandedOptions.add(opt);
          }
          continue;
        }

        final firstLeg = opt.busLegs.first;
        final String key = '${firstLeg.fromStopId}_${firstLeg.busNumber}';
        final departures = timetableMap[key];

        if (departures == null) {
          if (addedSignatures.add(_optionSignature(opt.busLegs))) {
            expandedOptions.add(opt);
          }
          continue;
        }

        for (var stData in departures) {
          final DateTime newScheduledDep = DateTime.fromMillisecondsSinceEpoch(
            stData.scheduledEpochSec * 1000,
          );
          final Duration offset = newScheduledDep.difference(
            firstLeg.departureTime,
          );

          // Onko tämä lähtö sama fyysinen vuoro kuin alkuperäisessä
          // reittiehdotuksessa? Vain silloin jatkovaiheiden trip-id:t
          // pitävät paikkansa – muille lähdöille ne kuvaisivat väärää
          // vuoroa ja live-feed antaisi väärän bussin aikoja.
          final bool isOriginalDeparture =
              stData.tripId.isNotEmpty &&
              firstLeg.tripId.isNotEmpty &&
              tripIdMatches(stData.tripId, firstLeg.tripId);

          final List<BusLeg> clonedLegs = [];
          for (int k = 0; k < opt.busLegs.length; k++) {
            final baseLeg = opt.busLegs[k];
            final bool isFirst = k == 0;
            clonedLegs.add(
              baseLeg.copyWith(
                tripId: isFirst
                    ? (stData.tripId.isNotEmpty
                          ? stData.tripId
                          : baseLeg.tripId)
                    : (isOriginalDeparture ? baseLeg.tripId : ''),
                departureTime: baseLeg.departureTime.add(offset),
                arrivalTime: baseLeg.arrivalTime.add(offset),
                realtimeDeparture: isFirst
                    ? DateTime.fromMillisecondsSinceEpoch(
                        stData.realtimeEpochSec * 1000,
                      )
                    : baseLeg.departureTime.add(offset),
                realtimeState: isFirst ? stData.realtimeState : 'SCHEDULED',
                isRealtime: isFirst ? stData.isRealtime : false,
              ),
            );
          }

          if (addedSignatures.add(_optionSignature(clonedLegs))) {
            expandedOptions.add(
              RouteOption(
                leaveHomeTime: opt.leaveHomeTime.add(offset),
                // Pidetään aikataulun mukaisena: viive lasketaan näyttöön
                // vain kerran (realArrivalTime), eikä se kertaudu tähän.
                arrivalTime: opt.arrivalTime.add(offset),
                busLegs: clonedLegs,
                segments: opt.segments,
                walkDistances: opt.walkDistances,
              ),
            );
          }
        }
      }
      return expandedOptions;
    } catch (e) {
      debugPrint('Timetable extension failed: $e');
      return parsedOptions;
    }
  }

  String _optionSignature(List<BusLeg> legs) => legs
      .map((l) => '${l.busNumber}_${l.departureTime.millisecondsSinceEpoch}')
      .join('|');
}
