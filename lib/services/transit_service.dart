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

  /// Bussien sijainnit Waltti GTFS-RT-feedistä. Viiveet haetaan
  /// reititys-API:sta ([fetchTripRealtime]) – feediä käytetään vain
  /// sijainteihin, joita reititys-API ei tarjoa.
  Future<FeedMessage?> fetchLiveBuses() => _fetchGtfsRtFeed('vehicleposition');

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
  /// Heittää poikkeuksen HTTP-virheestä, aikakatkaisusta tai jos vastauksessa
  /// ei ole dataa lainkaan. GraphQL palauttaa virheet HTTP 200:lla, joten ne
  /// kirjataan lokiin myös silloin, kun osa datasta tuli perille (esim. yksi
  /// aliasoitu vuoro puuttuu).
  Future<Map<String, dynamic>> _runGraphQl(String query) async {
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
    final decoded = json.decode(response.body) as Map<String, dynamic>;

    final errors = decoded['errors'];
    final String errorText = errors is List && errors.isNotEmpty
        ? errors.map((e) => e is Map ? e['message'] : e).join('; ')
        : '';
    if (errorText.isNotEmpty) {
      debugPrint('GraphQL errors: $errorText');
    }

    final data = decoded['data'] as Map<String, dynamic>?;
    if (data == null) {
      throw Exception(
        'GraphQL error: ${errorText.isEmpty ? 'no data' : errorText}',
      );
    }
    return data;
  }

  /// stoptimesForDate-kentän argumentti. Ilman päivää OTP käyttää kuluvaa
  /// liikennöintipäivää. Muoto tarkistetaan, koska arvo upotetaan kyselyyn.
  static String _serviceDateArg(String serviceDate) =>
      RegExp(r'^\d{8}$').hasMatch(serviceDate)
      ? '(serviceDate: "$serviceDate")'
      : '';

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
      final stops = data['stopsByBbox'] as List<dynamic>?;
      if (stops != null) {
        return stops.map((st) => Map<String, dynamic>.from(st)).toList();
      }
    } catch (err) {
      debugPrint('Error fetching stops: $err');
    }
    return [];
  }

  /// Vuoron kaikki pysäkit ajoineen. Trip.stoptimes palauttaisi pelkän
  /// aikataulun ilman päivää (serviceDay -1), joten käytetään
  /// stoptimesForDate-kenttää, joka sisältää myös reaaliaikatiedon.
  Future<List<Map<String, dynamic>>?> fetchTripRoute(
    String tripId, {
    String serviceDate = '',
  }) async {
    if (tripId.isEmpty) return null;

    final String query =
        """
    {
      trip(id: "$tripId") {
        stoptimesForDate${_serviceDateArg(serviceDate)} {
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
      final tripData = data['trip'];

      if (tripData != null && tripData['stoptimesForDate'] != null) {
        final stoptimes = tripData['stoptimesForDate'] as List<dynamic>;
        return stoptimes.map((st) => Map<String, dynamic>.from(st)).toList();
      }
    } catch (e) {
      debugPrint('Error fetching full trip route: $e');
    }
    return null;
  }

  /// Pysäkin seuraavat lähdöt aikataulunäyttöä varten. Perutut lähdöt ovat
  /// mukana (omitCanceled: false), jotta ne voidaan näyttää perutuiksi
  /// sen sijaan, että ne vain katoaisivat listalta.
  /// Heittää poikkeuksen virhetilanteessa, jotta UI voi näyttää virheen
  /// ja tarjota uudelleenyrityksen.
  Future<List<StopTimeData>> fetchStopDepartures(String stopId) async {
    if (stopId.isEmpty) return [];
    final int startTimeSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final String query =
        """
    {
      stop(id: "$stopId") {
        stoptimesWithoutPatterns(startTime: $startTimeSec, timeRange: 7200, numberOfDepartures: 20, omitCanceled: false) {
          scheduledDeparture realtimeDeparture realtimeState realtime serviceDay headsign
          trip { gtfsId route { shortName gtfsId } }
        }
      }
    }
    """;

    final data = await _runGraphQl(query);
    final stoptimes =
        data['stop']?['stoptimesWithoutPatterns'] as List<dynamic>?;
    if (stoptimes == null) return [];
    return stoptimes
        .map((st) => _parseStopTime(st as Map<String, dynamic>))
        .whereType<StopTimeData>()
        .toList();
  }

  static const int _maxRealtimeTrips = 30;

  /// Hakee vaiheiden vuorojen pysäkkikohtaiset reaaliaikatiedot
  /// reititys-API:sta. [legs] annetaan tärkeysjärjestyksessä: jos vuoroja
  /// on enemmän kuin kyselyyn mahtuu, alkupään vuorot säilyvät.
  ///
  /// Digitransitin ohjeen mukaan trip updatet on integroitu reititys-API:in,
  /// joten viiveet haetaan sieltä trip-gtfsId:llä – id:t ovat samasta
  /// järjestelmästä kuin reittiehdotukset, eikä raakaan GTFS-RT-feediin
  /// tarvita epävarmaa trip-id-täsmäystä. (Waltti-feediä käytetään enää
  /// bussien sijainteihin, joita reititys-API ei tarjoa.)
  ///
  /// Kenttä on stoptimesForDate eikä stoptimes: jälkimmäinen palauttaa
  /// OTP2:ssa pelkän aikataulun (realtime aina false, serviceDay -1), jolloin
  /// yksikään viive ei koskaan päivittyisi.
  ///
  /// Palauttaa null virhetilanteessa, jolloin kutsuja voi pitää vanhan
  /// datan ja merkitä sen vanhentuneeksi.
  Future<Map<String, TripRealtime>?> fetchTripRealtime(
    List<BusLeg> legs,
  ) async {
    // trip-gtfsId → liikennöintipäivä, lisäysjärjestys = tärkeysjärjestys.
    final Map<String, String> serviceDateByTrip = {};
    for (final leg in legs) {
      if (leg.tripId.isEmpty || serviceDateByTrip.containsKey(leg.tripId)) {
        continue;
      }
      serviceDateByTrip[leg.tripId] = leg.serviceDate;
      if (serviceDateByTrip.length == _maxRealtimeTrips) break;
    }
    if (serviceDateByTrip.isEmpty) return {};

    String tripQueries = '';
    int i = 0;
    serviceDateByTrip.forEach((tripId, serviceDate) {
      tripQueries +=
          """
        trip$i: trip(id: "$tripId") {
          gtfsId
          stoptimesForDate${_serviceDateArg(serviceDate)} {
            stop { gtfsId }
            scheduledArrival scheduledDeparture
            realtimeArrival realtimeDeparture realtime realtimeState serviceDay
          }
        }
      """;
      i++;
    });

    try {
      final data = await _runGraphQl('{ $tripQueries }');

      final Map<String, TripRealtime> result = {};
      data.forEach((alias, tripData) {
        if (tripData == null || tripData['gtfsId'] == null) return;
        final stoptimes = tripData['stoptimesForDate'] as List<dynamic>?;
        if (stoptimes == null) return;

        // Kaikki käynnit talteen: rengasreitti voi käydä samalla pysäkillä
        // kahdesti, ja oikea käynti valitaan aikataulun perusteella.
        final Map<String, List<StopRealtime>> visitsByStopId = {};
        for (final st in stoptimes) {
          // Vain oikea reaaliaikatieto kelpaa – muuten aikataulun aika
          // näkyisi käyttäjälle "live-tietona".
          if (st['realtime'] != true) continue;
          final String? stopId = st['stop']?['gtfsId'];
          final int? serviceDay = st['serviceDay'];
          if (stopId == null || serviceDay == null || serviceDay <= 0) {
            continue;
          }

          DateTime? toTime(int? secs) => secs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch((serviceDay + secs) * 1000);

          visitsByStopId
              .putIfAbsent(stopId, () => [])
              .add(
                StopRealtime(
                  arrival: toTime(st['realtimeArrival'] as int?),
                  departure: toTime(st['realtimeDeparture'] as int?),
                  realtimeState: st['realtimeState'] ?? 'UPDATED',
                  scheduled: toTime(
                    (st['scheduledDeparture'] ?? st['scheduledArrival'])
                        as int?,
                  ),
                ),
              );
        }
        if (visitsByStopId.isNotEmpty) {
          result[tripData['gtfsId'] as String] = TripRealtime.fromVisits(
            visitsByStopId,
          );
        }
      });
      return result;
    } catch (e) {
      debugPrint('Trip realtime fetch error: $e');
      return null;
    }
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
      patternCode: st['trip']?['pattern']?['code'] ?? '',
      serviceDayEpochSec: serviceDay,
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

    final plan = data['plan'];
    if (plan == null) {
      // Ilman plan-osaa kysely epäonnistui (virheet on jo kirjattu) – ei
      // tulkita sitä "ei reittejä" -tilanteeksi.
      throw Exception('Route plan missing from response');
    }
    final itineraries = plan['itineraries'] as List<dynamic>?;
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

    // Järjestys samalla lähtöajalla kuin kortissa näytetään (viive mukana).
    parsedOptions.sort(
      (a, b) =>
          displayedLeaveTime(a, null).compareTo(displayedLeaveTime(b, null)),
    );
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
            departureDelay arrivalDelay realTime realtimeState serviceDate
            interlineWithPreviousLeg
            trip { gtfsId pattern { code } }
            route { shortName gtfsId alerts { alertHeaderText effectiveStartDate effectiveEndDate } }
            alerts { alertHeaderText effectiveStartDate effectiveEndDate trip { gtfsId } }
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

  /// OTP:n viivekenttä sekunteina (puuttuu tai null = ei viivettä).
  static int _delaySec(dynamic value) => (value as num?)?.toInt() ?? 0;

  static DateTime? _epochSecToDate(dynamic value) =>
      value is num && value > 0
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt() * 1000)
      : null;

  /// OTP:n startTime/endTime sisältävät reaaliaikatiedon
  /// (aikataulu = startTime - departureDelay). Sovelluksen RouteOption- ja
  /// BusLeg-ajat pidetään aikataulun mukaisina ja viive lisätään näyttöön
  /// vain kerran, joten viiveet vähennetään tässä pois.
  RouteOption _parseItinerary(Map<String, dynamic> itinerary) {
    final List<RouteSegment> segments = [];
    final List<BusLeg> busLegs = [];
    final List<double> walkDistances = [];
    final List<Duration> walkDurations = [];

    double currentWalk = 0.0;
    Duration currentWalkDuration = Duration.zero;
    int? firstDepartureDelaySec;
    int lastArrivalDelaySec = 0;

    for (var leg in itinerary['legs']) {
      if (leg['mode'] == 'WALK') {
        currentWalk += (leg['distance'] as num).toDouble();
        currentWalkDuration += Duration(
          milliseconds:
              (leg['endTime'] as num).toInt() -
              (leg['startTime'] as num).toInt(),
        );
      }

      if (leg['mode'] == 'BUS') {
        walkDistances.add(currentWalk);
        walkDurations.add(currentWalkDuration);
        currentWalk = 0.0;
        currentWalkDuration = Duration.zero;
        busLegs.add(_parseBusLeg(leg));
        firstDepartureDelaySec ??= _delaySec(leg['departureDelay']);
        lastArrivalDelaySec = _delaySec(leg['arrivalDelay']);
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
    walkDurations.add(currentWalkDuration);

    final DateTime leaveHome = DateTime.fromMillisecondsSinceEpoch(
      itinerary['startTime'],
    ).subtract(Duration(seconds: firstDepartureDelaySec ?? 0));
    final DateTime arrival = DateTime.fromMillisecondsSinceEpoch(
      itinerary['endTime'],
    ).subtract(Duration(seconds: lastArrivalDelaySec));

    return RouteOption(
      leaveHomeTime: leaveHome,
      arrivalTime: arrival,
      busLegs: busLegs,
      segments: segments,
      walkDistances: walkDistances,
      walkDurations: walkDurations,
    );
  }

  BusLeg _parseBusLeg(Map<String, dynamic> leg) {
    final String fromStopId = leg['from']?['stop']?['gtfsId'] ?? '';
    final String toStopId = leg['to']?['stop']?['gtfsId'] ?? '';
    final String tripId = leg['trip']?['gtfsId'] ?? '';
    // startTime/endTime sisältävät reaaliaikatiedon, ks. _parseItinerary.
    final DateTime realtimeDep = DateTime.fromMillisecondsSinceEpoch(
      leg['startTime'],
    );
    final DateTime realtimeArr = DateTime.fromMillisecondsSinceEpoch(
      leg['endTime'],
    );
    final DateTime scheduledDep = realtimeDep.subtract(
      Duration(seconds: _delaySec(leg['departureDelay'])),
    );
    final DateTime scheduledArr = realtimeArr.subtract(
      Duration(seconds: _delaySec(leg['arrivalDelay'])),
    );
    final bool isRealtime = leg['realTime'] == true;
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

    // Vaiheen tiedotteet kattavat linjan lisäksi vuoron, pysäkit ja
    // liikennöitsijän (esim. yksittäisen vuoron poikkeusreitti). Linjan
    // kaikki tiedotteet otetaan mukaan voimassaoloajasta riippumatta, jotta
    // aikataulusta kopioitu myöhempi lähtö saa omaan aikaansa osuvat
    // tiedotteet – voimassaolo tarkistetaan näytettäessä (activeLegAlerts).
    final List<AlertInfo> alerts = [];
    final Set<String> seenAlerts = {};
    void addAlerts(List<dynamic>? rawAlerts) {
      for (final a in rawAlerts ?? const []) {
        final String text = a['alertHeaderText']?.toString() ?? '';
        if (text.isEmpty) continue;
        final alert = AlertInfo(
          text: text,
          effectiveStart: _epochSecToDate(a['effectiveStartDate']),
          effectiveEnd: _epochSecToDate(a['effectiveEndDate']),
          tripId: a['trip']?['gtfsId'] ?? '',
        );
        if (seenAlerts.add(
          '$text|${alert.effectiveStart}|${alert.effectiveEnd}|${alert.tripId}',
        )) {
          alerts.add(alert);
        }
      }
    }

    addAlerts(leg['alerts'] as List<dynamic>?);
    addAlerts(leg['route']?['alerts'] as List<dynamic>?);

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
      arrivalTime: scheduledArr,
      realtimeDeparture: realtimeDep,
      // Saapumisviive voi poiketa lähdön viiveestä (viive kasvaa tai
      // kutistuu matkalla), joten OTP:n ennuste säilytetään erikseen.
      realtimeArrival: isRealtime ? realtimeArr : null,
      realtimeState:
          leg['realtimeState'] ?? (isRealtime ? 'UPDATED' : 'SCHEDULED'),
      isRealtime: isRealtime,
      stayOnBus: stayOnBus,
      intermediateStops: intermediateStops,
      alerts: alerts,
      // Digitransit palauttaa päivän muodossa 2026-10-06, vaikka
      // dokumentaatio sanoo YYYYMMDD – yhtenäistetään YYYYMMDD-muotoon.
      serviceDate: (leg['serviceDate'] as String? ?? '').replaceAll('-', ''),
      patternCode: leg['trip']?['pattern']?['code'] ?? '',
    );
  }

  /// Aikataulun ryhmittelyavain: nousupysäkki + vuoron pysäkkijärjestys.
  /// Pelkkä linjatunnus ei riitä, koska saman linjan vuorot voivat kulkea
  /// eri reittiä tai päättyä aiemmin. Linjatunnus on varalla, jos OTP ei
  /// palauta pattern-koodia.
  static String _timetableKey(
    String stopId,
    String patternCode,
    String busNumber,
  ) => patternCode.isNotEmpty ? '${stopId}_$patternCode' : '${stopId}_$busNumber';

  static String _departureKey(String timetableKey, DateTime scheduledDep) =>
      '$timetableKey@${scheduledDep.millisecondsSinceEpoch}';

  /// Laajentaa reittivaihtoehdot ensimmäisen nousupysäkin aikataululla:
  /// samasta reittiketjusta luodaan vaihtoehto jokaiselle saman
  /// pysäkkijärjestyksen lähtövuorolle, jota OTP ei itse ehdottanut.
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
          stoptimesWithoutPatterns(startTime: $startTimeSec, timeRange: 7200, numberOfDepartures: 30, omitNonPickups: true) {
            scheduledDeparture realtimeDeparture realtimeState realtime serviceDay
            trip { gtfsId pattern { code } route { shortName } }
          }
        }
      """;
      i++;
    }

    try {
      final ttDataMap = await _runGraphQl('{ $stopQueries }');

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
              .putIfAbsent(
                _timetableKey(sId, parsed.patternCode, parsed.busNumber ?? ''),
                () => [],
              )
              .add(parsed);
        }
      });

      final List<RouteOption> expandedOptions = [];
      final Set<String> addedSignatures = {};

      // OTP:n omat ehdotukset ensin: niissä vaihtoyhteydet, trip-id:t ja
      // ajat ovat oikeat. Kloonit vain täydentävät lähtöjä, joita OTP ei
      // ehdottanut – muuten kopio voisi korvata OTP:n tarkan ehdotuksen.
      final Set<String> coveredDepartures = {};
      for (final opt in parsedOptions) {
        if (opt.busLegs.isEmpty) {
          final String sig =
              'walk_only_${(opt.arrivalTime.millisecondsSinceEpoch / 600000).round()}';
          if (addedSignatures.add(sig)) {
            expandedOptions.add(opt);
          }
          continue;
        }
        if (addedSignatures.add(_optionSignature(opt.busLegs))) {
          expandedOptions.add(opt);
        }
        final first = opt.busLegs.first;
        if (first.tripId.isNotEmpty) coveredDepartures.add(first.tripId);
        coveredDepartures.add(
          _departureKey(
            _timetableKey(first.fromStopId, first.patternCode, first.busNumber),
            first.departureTime,
          ),
        );
      }

      // Kopiopohjiksi kelpaavat vain yhden bussin reitit: vaihdollisen reitin
      // jatkobussi kulkisi kopiossa keksittyyn aikaan, joten vaihtoreittien
      // vaihtoehdot tulevat vain OTP:ltä. Samalle pysäkille ja vuoron
      // pysäkkijärjestykselle valitaan nopein pohja, ettei samasta lähdöstä
      // synny useaa korttia (esim. eri poistumispysäkki).
      final Map<String, RouteOption> templates = {};
      for (final opt in parsedOptions) {
        if (opt.busLegs.length != 1) continue;
        final leg = opt.busLegs.single;
        final String key = _timetableKey(
          leg.fromStopId,
          leg.patternCode,
          leg.busNumber,
        );
        final RouteOption? current = templates[key];
        if (current == null ||
            _doorToDoor(opt).compareTo(_doorToDoor(current)) < 0) {
          templates[key] = opt;
        }
      }

      templates.forEach((key, opt) {
        final departures = timetableMap[key];
        if (departures == null) return;
        final BusLeg templateLeg = opt.busLegs.single;

        for (final stData in departures) {
          final DateTime newScheduledDep = DateTime.fromMillisecondsSinceEpoch(
            stData.scheduledEpochSec * 1000,
          );
          if ((stData.tripId.isNotEmpty &&
                  coveredDepartures.contains(stData.tripId)) ||
              coveredDepartures.contains(_departureKey(key, newScheduledDep))) {
            continue;
          }
          final Duration offset = newScheduledDep.difference(
            templateLeg.departureTime,
          );
          final DateTime realtimeDep = DateTime.fromMillisecondsSinceEpoch(
            stData.realtimeEpochSec * 1000,
          );

          // Lähtöön ei ehdi, jos kävely pysäkille pitäisi aloittaa ennen
          // hakuaikaa (bussin viive huomioiden).
          final DateTime leave = opt.leaveHomeTime
              .add(offset)
              .add(realtimeDep.difference(newScheduledDep));
          if (leave.isBefore(departureTime)) continue;

          final BusLeg clonedLeg = templateLeg.copyWith(
            tripId: stData.tripId,
            serviceDate: stData.serviceDate,
            departureTime: newScheduledDep,
            arrivalTime: templateLeg.arrivalTime.add(offset),
            realtimeDeparture: realtimeDep,
            // Pysäkkiaikataulusta tiedetään vain lähdön viive.
            clearRealtimeArrival: true,
            realtimeState: stData.realtimeState,
            isRealtime: stData.isRealtime,
            // Pohjavuoron omat tiedotteet eivät koske toista vuoroa.
            alerts: templateLeg.alerts
                .where((a) => a.tripId.isEmpty || a.tripId == stData.tripId)
                .toList(),
          );

          if (addedSignatures.add(_optionSignature([clonedLeg]))) {
            expandedOptions.add(
              RouteOption(
                leaveHomeTime: opt.leaveHomeTime.add(offset),
                // Pidetään aikataulun mukaisena: viive lasketaan näyttöön
                // vain kerran (realArrivalTime), eikä se kertaudu tähän.
                arrivalTime: opt.arrivalTime.add(offset),
                busLegs: [clonedLeg],
                segments: opt.segments,
                walkDistances: opt.walkDistances,
                walkDurations: opt.walkDurations,
              ),
            );
          }
        }
      });
      return expandedOptions;
    } catch (e) {
      debugPrint('Timetable extension failed: $e');
      return parsedOptions;
    }
  }

  static Duration _doorToDoor(RouteOption option) =>
      option.arrivalTime.difference(option.leaveHomeTime);

  String _optionSignature(List<BusLeg> legs) => legs
      .map(
        (l) =>
            '${l.busNumber}_${l.fromStopId}_${l.toStopId}_'
            '${l.departureTime.millisecondsSinceEpoch}',
      )
      .join('|');
}
