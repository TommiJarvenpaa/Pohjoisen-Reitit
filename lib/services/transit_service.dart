import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import '../models/app_models.dart';

class TransitService {
  final String digitransitKey;
  final String walttiClientId;
  final String walttiClientSecret;

  TransitService({
    required this.digitransitKey,
    required this.walttiClientId,
    required this.walttiClientSecret,
  });

  Future<List<Place>> getAutocompleteSuggestions(String query) async {
    if (query.isEmpty) return [];
    try {
      final response = await http.get(
        Uri.parse(
          'https://api.digitransit.fi/geocoding/v1/autocomplete?text=$query'
          '&boundary.rect.min_lat=64.7&boundary.rect.max_lat=65.45'
          '&boundary.rect.min_lon=24.9&boundary.rect.max_lon=26.5',
        ),
        headers: {'digitransit-subscription-key': digitransitKey},
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final features = data['features'] as List<dynamic>;
        return features
            .map(
              (f) => Place(
                name: f['properties']['name'],
                label: f['properties']['label'],
                lat: f['geometry']['coordinates'][1],
                lon: f['geometry']['coordinates'][0],
              ),
            )
            .toList();
      }
    } catch (e) {
      debugPrint('Autocomplete error: $e');
    }
    return [];
  }

  Future<FeedMessage?> fetchLiveBuses() async {
    final String encodedCredentials = base64Encode(
      utf8.encode('$walttiClientId:$walttiClientSecret'),
    );
    try {
      final response = await http.get(
        Uri.parse(
          'https://data.waltti.fi/oulu/api/gtfsrealtime/v1.0/feed/vehicleposition',
        ),
        headers: {'Authorization': 'Basic $encodedCredentials'},
      );
      if (response.statusCode == 200) {
        return FeedMessage.fromBuffer(response.bodyBytes);
      }
    } catch (e) {
      debugPrint('Live bus fetch error: $e');
    }
    return null;
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
      final response = await http.post(
        Uri.parse('https://api.digitransit.fi/routing/v2/waltti/gtfs/v1'),
        headers: {
          'Content-Type': 'application/json',
          'digitransit-subscription-key': digitransitKey,
        },
        body: json.encode({'query': query}),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final stops = data['data']?['stopsByBbox'] as List<dynamic>?;
        if (stops != null) {
          return stops.map((st) => Map<String, dynamic>.from(st)).toList();
        }
      }
    } catch (err) {
      debugPrint('Error fetching stops: $err');
    }
    return [];
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
    final routeUrl = Uri.parse(
      'https://api.digitransit.fi/routing/v2/waltti/gtfs/v1',
    );
    final int searchWindow = isFallback ? 86400 : 10800;

    final String baseQuery =
        """
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
            route { shortName gtfsId alerts { alertHeaderText } }
            from { name lat lon stop { gtfsId } }
            to { name lat lon }
            legGeometry { points }
            intermediateStops { name lat lon }
          }
        }
      }
    }
    """;

    final response = await http.post(
      routeUrl,
      headers: {
        'Content-Type': 'application/json',
        'digitransit-subscription-key': digitransitKey,
      },
      body: json.encode({'query': baseQuery}),
    );

    if (response.statusCode != 200) {
      throw Exception('API Error: ${response.statusCode}');
    }
    final data = json.decode(response.body);
    if (data['data'] == null ||
        data['data']['plan'] == null ||
        data['data']['plan']['itineraries'].isEmpty) {
      if (!isFallback) {
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

    final itineraries = data['data']['plan']['itineraries'];
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
        isFallback: false,
      );
    }

    List<RouteOption> parsedOptions = [];

    for (var itinerary in itineraries) {
      DateTime leaveHome = DateTime.fromMillisecondsSinceEpoch(
        itinerary['startTime'],
      );
      DateTime arrival = DateTime.fromMillisecondsSinceEpoch(
        itinerary['endTime'],
      );
      List<RouteSegment> segments = [];
      List<BusLeg> busLegs = [];
      List<double> walkDistances = [];

      double currentWalk = 0.0;

      for (var leg in itinerary['legs']) {
        if (leg['mode'] == 'WALK') {
          currentWalk += (leg['distance'] as num).toDouble();
        }

        if (leg['mode'] == 'BUS') {
          walkDistances.add(currentWalk);
          currentWalk = 0.0;

          String stopId = leg['from']?['stop']?['gtfsId'] ?? '';
          DateTime scheduledDep = DateTime.fromMillisecondsSinceEpoch(
            leg['startTime'],
          );
          double? fromLat = (leg['from']?['lat'] as num?)?.toDouble();
          double? fromLon = (leg['from']?['lon'] as num?)?.toDouble();
          double? toLat = (leg['to']?['lat'] as num?)?.toDouble();
          double? toLon = (leg['to']?['lon'] as num?)?.toDouble();

          // <-- UUSI: Luetaan interline-tieto
          bool stayOnBus = leg['interlineWithPreviousLeg'] ?? false;

          List<IntermediateStop> intermediateStops = [];
          final rawStops = leg['intermediateStops'] as List<dynamic>?;
          if (rawStops != null) {
            for (var s in rawStops) {
              if (s['lat'] != null && s['lon'] != null) {
                intermediateStops.add(
                  IntermediateStop(
                    name: s['name'] ?? '',
                    lat: (s['lat'] as num).toDouble(),
                    lon: (s['lon'] as num).toDouble(),
                  ),
                );
              }
            }
          }

          List<AlertInfo> alerts = [];
          final rawAlerts = leg['route']?['alerts'] as List<dynamic>?;
          if (rawAlerts != null) {
            for (var a in rawAlerts) {
              final text = a['alertHeaderText'];
              if (text != null && text.toString().isNotEmpty) {
                alerts.add(AlertInfo(text: text.toString()));
              }
            }
          }

          busLegs.add(
            BusLeg(
              busNumber: leg['route']['shortName'] ?? 'Bussi',
              routeGtfsId: leg['route']['gtfsId'] ?? '',
              fromStop: leg['from']['name'] ?? 'Tuntematon pysäkki',
              fromStopId: stopId,
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
              stayOnBus: stayOnBus, // <-- UUSI: Talletetaan tieto BusLegiin
              intermediateStops: intermediateStops,
              alerts: alerts,
            ),
          );
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

      parsedOptions.add(
        RouteOption(
          leaveHomeTime: leaveHome,
          arrivalTime: arrival,
          busLegs: busLegs,
          segments: segments,
          walkDistances: walkDistances,
        ),
      );
    }

    Set<String> stopIdsToQuery = {};
    for (var opt in parsedOptions) {
      if (opt.busLegs.isNotEmpty && opt.busLegs.first.fromStopId.isNotEmpty) {
        stopIdsToQuery.add(opt.busLegs.first.fromStopId);
      }
    }

    if (stopIdsToQuery.isNotEmpty) {
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
              trip { route { shortName } }
            }
          }
        """;
        i++;
      }

      try {
        final ttResponse = await http.post(
          routeUrl,
          headers: {
            'Content-Type': 'application/json',
            'digitransit-subscription-key': digitransitKey,
          },
          body: json.encode({'query': '{ $stopQueries }'}),
        );

        if (ttResponse.statusCode == 200) {
          final ttData = json.decode(ttResponse.body);
          final ttDataMap = ttData['data'] as Map<String, dynamic>?;

          if (ttDataMap != null) {
            Map<String, List<StopTimeData>> timetableMap = {};

            ttDataMap.forEach((alias, stopData) {
              if (stopData != null && stopData['gtfsId'] != null) {
                String sId = stopData['gtfsId'];
                var stoptimes =
                    stopData['stoptimesWithoutPatterns'] as List<dynamic>?;

                if (stoptimes != null) {
                  for (var st in stoptimes) {
                    String? rName = st['trip']?['route']?['shortName'];
                    int? schedDep = st['scheduledDeparture'];
                    int? realDep = st['realtimeDeparture'];
                    int? serviceDay = st['serviceDay'];
                    String rtState = st['realtimeState'] ?? 'SCHEDULED';
                    bool isRt = st['realtime'] ?? false;

                    if (rName != null &&
                        schedDep != null &&
                        serviceDay != null) {
                      String key = '${sId}_$rName';
                      timetableMap
                          .putIfAbsent(key, () => [])
                          .add(
                            StopTimeData(
                              scheduledEpochSec: serviceDay + schedDep,
                              realtimeEpochSec:
                                  serviceDay + (realDep ?? schedDep),
                              realtimeState: rtState,
                              isRealtime: isRt,
                            ),
                          );
                    }
                  }
                }
              }
            });

            List<RouteOption> expandedOptions = [];
            Set<String> addedSignatures = {};

            for (var opt in parsedOptions) {
              if (opt.busLegs.isEmpty) {
                String sig =
                    'walk_only_${(opt.arrivalTime.millisecondsSinceEpoch / 600000).round()}';
                if (!addedSignatures.contains(sig)) {
                  addedSignatures.add(sig);
                  expandedOptions.add(opt);
                }
                continue;
              }

              var firstLeg = opt.busLegs.first;
              String key = '${firstLeg.fromStopId}_${firstLeg.busNumber}';

              if (timetableMap.containsKey(key)) {
                for (var stData in timetableMap[key]!) {
                  DateTime newScheduledDep =
                      DateTime.fromMillisecondsSinceEpoch(
                        stData.scheduledEpochSec * 1000,
                      );
                  Duration offset = newScheduledDep.difference(
                    firstLeg.departureTime,
                  );

                  List<BusLeg> clonedLegs = [];
                  for (int k = 0; k < opt.busLegs.length; k++) {
                    var baseLeg = opt.busLegs[k];
                    DateTime legRealDep = baseLeg.departureTime.add(offset);
                    String state = 'SCHEDULED';
                    bool isRt = false;

                    if (k == 0) {
                      legRealDep = DateTime.fromMillisecondsSinceEpoch(
                        stData.realtimeEpochSec * 1000,
                      );
                      state = stData.realtimeState;
                      isRt = stData.isRealtime;
                    }

                    clonedLegs.add(
                      BusLeg(
                        busNumber: baseLeg.busNumber,
                        routeGtfsId: baseLeg.routeGtfsId,
                        fromStop: baseLeg.fromStop,
                        fromStopId: baseLeg.fromStopId,
                        fromLat: baseLeg.fromLat,
                        fromLon: baseLeg.fromLon,
                        toStop: baseLeg.toStop,
                        toLat: baseLeg.toLat,
                        toLon: baseLeg.toLon,
                        departureTime: baseLeg.departureTime.add(offset),
                        arrivalTime: baseLeg.arrivalTime.add(offset),
                        realtimeDeparture: legRealDep,
                        realtimeState: state,
                        isRealtime: isRt,
                        stayOnBus: baseLeg.stayOnBus,
                        intermediateStops: baseLeg.intermediateStops,
                        alerts: baseLeg.alerts,
                      ),
                    );
                  }

                  String sig = clonedLegs
                      .map(
                        (l) =>
                            '${l.busNumber}_${l.departureTime.millisecondsSinceEpoch}',
                      )
                      .join('|');

                  if (!addedSignatures.contains(sig)) {
                    addedSignatures.add(sig);
                    Duration firstLegDelay = clonedLegs.first.realtimeDeparture
                        .difference(clonedLegs.first.departureTime);
                    expandedOptions.add(
                      RouteOption(
                        leaveHomeTime: opt.leaveHomeTime.add(offset),
                        arrivalTime: opt.arrivalTime
                            .add(offset)
                            .add(firstLegDelay),
                        busLegs: clonedLegs,
                        segments: opt.segments,
                        walkDistances: opt.walkDistances,
                      ),
                    );
                  }
                }
              } else {
                String sig = opt.busLegs
                    .map(
                      (l) =>
                          '${l.busNumber}_${l.departureTime.millisecondsSinceEpoch}',
                    )
                    .join('|');
                if (!addedSignatures.contains(sig)) {
                  addedSignatures.add(sig);
                  expandedOptions.add(opt);
                }
              }
            }
            parsedOptions = expandedOptions;
          }
        }
      } catch (e) {
        debugPrint('Timetable extension failed: $e');
      }
    }

    parsedOptions.sort((a, b) => a.leaveHomeTime.compareTo(b.leaveHomeTime));
    return parsedOptions;
  }
}
