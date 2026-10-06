import 'package:latlong2/latlong.dart';

List<String> _parseStringList(dynamic value) {
  if (value is! List) return [];
  return value.map((e) => e?.toString() ?? '').toList();
}

class Place {
  final String name;
  final double lat;
  final double lon;
  final String? label;

  Place({required this.name, required this.lat, required this.lon, this.label});

  Map<String, dynamic> toJson() => {
    'name': name,
    'lat': lat,
    'lon': lon,
    'label': label,
  };

  factory Place.fromJson(Map<String, dynamic> json) => Place(
    name: json['name'],
    lat: (json['lat'] as num).toDouble(),
    lon: (json['lon'] as num).toDouble(),
    label: json['label'],
  );
}

class AlertInfo {
  final String text;

  /// Tiedotteen voimassaolo. Null = rajaamaton (tai tieto puuttuu, esim.
  /// välimuistista ladattu tiedote).
  final DateTime? effectiveStart;
  final DateTime? effectiveEnd;

  /// Vuoro, jota tiedote koskee (tyhjä = ei vuorokohtainen). Kopioidulle
  /// lähdölle toisen vuoron tiedote ei kuulu.
  final String tripId;

  AlertInfo({
    required this.text,
    this.effectiveStart,
    this.effectiveEnd,
    this.tripId = '',
  });

  /// Onko tiedote voimassa jossain kohtaa aikaväliä [from]–[to].
  bool isActiveBetween(DateTime from, DateTime to) {
    if (effectiveStart != null && effectiveStart!.isAfter(to)) return false;
    if (effectiveEnd != null && effectiveEnd!.isBefore(from)) return false;
    return true;
  }
}

class IntermediateStop {
  final String name;
  final double lat;
  final double lon;
  final String? gtfsId;

  IntermediateStop({
    required this.name,
    required this.lat,
    required this.lon,
    this.gtfsId,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'lat': lat,
        'lon': lon,
        if (gtfsId != null) 'gtfsId': gtfsId,
      };

  factory IntermediateStop.fromJson(Map<String, dynamic> json) {
    final lat = json['lat'];
    final lon = json['lon'];
    if (lat == null || lon == null) {
      return IntermediateStop(
        name: json['name'] ?? '',
        lat: 0,
        lon: 0,
        gtfsId: json['gtfsId'] as String?,
      );
    }
    return IntermediateStop(
      name: json['name'] ?? '',
      lat: (lat as num).toDouble(),
      lon: (lon as num).toDouble(),
      gtfsId: json['gtfsId'] as String?,
    );
  }
}

/// Yhden pysäkin reaaliaikaiset ajat tietyllä vuorolla.
/// Ajat tulevat reititys-API:sta (OTP), johon trip updatet on jo
/// integroitu – ei raakaa GTFS-RT-feediä.
class StopRealtime {
  final DateTime? arrival;
  final DateTime? departure;
  final String realtimeState;

  /// Pysäkin aikataulun mukainen aika. Erottaa saman pysäkin käynnit
  /// toisistaan, jos vuoro käy pysäkillä kahdesti (rengasreitti).
  final DateTime? scheduled;

  StopRealtime({
    this.arrival,
    this.departure,
    this.realtimeState = 'UPDATED',
    this.scheduled,
  });
}

/// Vuoron reaaliaikatiedot pysäkeittäin, avaimena pysäkin gtfsId.
/// Sisältää vain pysäkit, joille on oikeaa reaaliaikadataa.
class TripRealtime {
  /// Pysäkin kaikki käynnit vuoron ajojärjestyksessä (yleensä yksi).
  final Map<String, List<StopRealtime>> visitsByStopId;

  /// Yksi käynti pysäkkiä kohden.
  TripRealtime({required Map<String, StopRealtime> byStopId})
    : visitsByStopId = {
        for (final e in byStopId.entries) e.key: [e.value],
      };

  TripRealtime.fromVisits(this.visitsByStopId);

  bool get isEmpty => visitsByStopId.isEmpty;

  /// Pysäkin käynti, jonka aikataulun mukainen aika on lähimpänä [near]:ia.
  StopRealtime? visitNear(String stopId, DateTime near) {
    final visits = visitsByStopId[stopId];
    if (visits == null || visits.isEmpty) return null;
    if (visits.length == 1) return visits.single;

    Duration distance(StopRealtime v) =>
        ((v.scheduled ?? v.departure ?? v.arrival)?.difference(near) ??
                const Duration(days: 1))
            .abs();
    return visits.reduce((a, b) => distance(b) < distance(a) ? b : a);
  }
}

class StopTimeData {
  final int scheduledEpochSec;
  final int realtimeEpochSec;
  final String realtimeState;
  final bool isRealtime;
  final String? busNumber;
  final String? headsign;
  final String tripId;
  final String routeGtfsId;

  /// Vuoron pysäkkijärjestys (OTP:n pattern code). Saman linjatunnuksen
  /// vuorot voivat kulkea eri reittiä (esim. koulureittivariantti).
  final String patternCode;

  /// Liikennöintipäivän alku (OTP:n serviceDay, epoch-sekunteina).
  final int serviceDayEpochSec;

  StopTimeData({
    required this.scheduledEpochSec,
    required this.realtimeEpochSec,
    required this.realtimeState,
    required this.isRealtime,
    this.busNumber,
    this.headsign,
    this.tripId = '',
    this.routeGtfsId = '',
    this.patternCode = '',
    this.serviceDayEpochSec = 0,
  });

  bool get isCanceled => realtimeState == 'CANCELED';

  /// Liikennöintipäivä muodossa YYYYMMDD (OTP:n stoptimesForDate-kyselyä
  /// varten). OTP:n serviceDay on "keskipäivä miinus 12 h", joten päivä
  /// luetaan keskipäivästä – kesäaikasiirtymäpäivinä keskiyö ei osu
  /// tasalle. Tyhjä, jos serviceDay puuttuu.
  String get serviceDate {
    if (serviceDayEpochSec <= 0) return '';
    final noon = DateTime.fromMillisecondsSinceEpoch(
      (serviceDayEpochSec + 12 * 3600) * 1000,
    );
    return '${noon.year}${noon.month.toString().padLeft(2, '0')}'
        '${noon.day.toString().padLeft(2, '0')}';
  }
}

class BusLeg {
  final String busNumber;
  final String routeGtfsId;
  final String tripId;
  final String fromStop;
  final String fromStopId;
  final String toStopId;
  final List<String> legStopIds;
  final double? fromLat;
  final double? fromLon;
  final String toStop;
  final double? toLat;
  final double? toLon;
  final DateTime departureTime;
  final DateTime arrivalTime;
  final DateTime realtimeDeparture;

  /// Hakuhetken reaaliaikainen saapumisaika (OTP:n endTime). Null, jos sitä
  /// ei tiedetä – esim. aikataulusta kopioidulla lähdöllä tiedetään vain
  /// lähdön viive. Käytetään vain, kun [isRealtime] on tosi.
  final DateTime? realtimeArrival;
  final String realtimeState;
  final bool isRealtime;
  final bool stayOnBus;
  final List<IntermediateStop> intermediateStops;
  final List<AlertInfo> alerts;

  /// Vuoron liikennöintipäivä (YYYYMMDD). Trip-gtfsId yksilöi vuoron mutta
  /// ei päivää, joten reaaliaikakysely tarvitsee molemmat. Tyhjä = tänään.
  final String serviceDate;

  /// Vuoron pysäkkijärjestys (OTP:n pattern code), ks. [StopTimeData].
  final String patternCode;

  BusLeg({
    required this.busNumber,
    this.routeGtfsId = '',
    this.tripId = '',
    required this.fromStop,
    required this.fromStopId,
    this.toStopId = '',
    this.legStopIds = const [],
    this.fromLat,
    this.fromLon,
    required this.toStop,
    this.toLat,
    this.toLon,
    required this.departureTime,
    required this.arrivalTime,
    required this.realtimeDeparture,
    this.realtimeArrival,
    required this.realtimeState,
    required this.isRealtime,
    this.stayOnBus = false,
    this.intermediateStops = const [],
    this.alerts = const [],
    this.serviceDate = '',
    this.patternCode = '',
  });

  BusLeg copyWith({
    String? busNumber,
    String? routeGtfsId,
    String? tripId,
    String? fromStop,
    String? fromStopId,
    String? toStopId,
    List<String>? legStopIds,
    double? fromLat,
    double? fromLon,
    String? toStop,
    double? toLat,
    double? toLon,
    DateTime? departureTime,
    DateTime? arrivalTime,
    DateTime? realtimeDeparture,
    DateTime? realtimeArrival,
    String? realtimeState,
    bool? isRealtime,
    bool? stayOnBus,
    List<IntermediateStop>? intermediateStops,
    List<AlertInfo>? alerts,
    String? serviceDate,
    String? patternCode,
    // copyWith ei muuten osaa asettaa null-arvoa.
    bool clearRealtimeArrival = false,
  }) {
    return BusLeg(
      busNumber: busNumber ?? this.busNumber,
      routeGtfsId: routeGtfsId ?? this.routeGtfsId,
      tripId: tripId ?? this.tripId,
      fromStop: fromStop ?? this.fromStop,
      fromStopId: fromStopId ?? this.fromStopId,
      toStopId: toStopId ?? this.toStopId,
      legStopIds: legStopIds ?? this.legStopIds,
      fromLat: fromLat ?? this.fromLat,
      fromLon: fromLon ?? this.fromLon,
      toStop: toStop ?? this.toStop,
      toLat: toLat ?? this.toLat,
      toLon: toLon ?? this.toLon,
      departureTime: departureTime ?? this.departureTime,
      arrivalTime: arrivalTime ?? this.arrivalTime,
      realtimeDeparture: realtimeDeparture ?? this.realtimeDeparture,
      realtimeArrival: clearRealtimeArrival
          ? null
          : (realtimeArrival ?? this.realtimeArrival),
      realtimeState: realtimeState ?? this.realtimeState,
      isRealtime: isRealtime ?? this.isRealtime,
      stayOnBus: stayOnBus ?? this.stayOnBus,
      intermediateStops: intermediateStops ?? this.intermediateStops,
      alerts: alerts ?? this.alerts,
      serviceDate: serviceDate ?? this.serviceDate,
      patternCode: patternCode ?? this.patternCode,
    );
  }

  Map<String, dynamic> toJson() => {
    'busNumber': busNumber,
    'routeGtfsId': routeGtfsId,
    'tripId': tripId,
    'fromStop': fromStop,
    'fromStopId': fromStopId,
    'toStopId': toStopId,
    'legStopIds': legStopIds,
    'fromLat': fromLat,
    'fromLon': fromLon,
    'toStop': toStop,
    'toLat': toLat,
    'toLon': toLon,
    'departureTime': departureTime.millisecondsSinceEpoch,
    'arrivalTime': arrivalTime.millisecondsSinceEpoch,
    'realtimeDeparture': realtimeDeparture.millisecondsSinceEpoch,
    'realtimeArrival': realtimeArrival?.millisecondsSinceEpoch,
    'realtimeState': realtimeState,
    'isRealtime': isRealtime,
    'stayOnBus': stayOnBus,
    'intermediateStops': intermediateStops.map((s) => s.toJson()).toList(),
    'alerts': alerts.map((a) => a.text).toList(),
    'serviceDate': serviceDate,
    'patternCode': patternCode,
  };

  factory BusLeg.fromJson(Map<String, dynamic> json) => BusLeg(
    busNumber: json['busNumber'] ?? '',
    routeGtfsId: json['routeGtfsId'] ?? '',
    tripId: json['tripId'] ?? '',
    fromStop: json['fromStop'] ?? '',
    fromStopId: json['fromStopId'] ?? '',
    toStopId: json['toStopId'] ?? '',
    legStopIds: _parseStringList(json['legStopIds']),
    fromLat: (json['fromLat'] as num?)?.toDouble(),
    fromLon: (json['fromLon'] as num?)?.toDouble(),
    toStop: json['toStop'] ?? '',
    toLat: (json['toLat'] as num?)?.toDouble(),
    toLon: (json['toLon'] as num?)?.toDouble(),
    departureTime: DateTime.fromMillisecondsSinceEpoch(
      json['departureTime'] ?? 0,
    ),
    arrivalTime: DateTime.fromMillisecondsSinceEpoch(json['arrivalTime'] ?? 0),
    realtimeDeparture: DateTime.fromMillisecondsSinceEpoch(
      json['realtimeDeparture'] ?? 0,
    ),
    realtimeArrival: json['realtimeArrival'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(json['realtimeArrival']),
    realtimeState: json['realtimeState'] ?? 'SCHEDULED',
    isRealtime: json['isRealtime'] ?? false,
    stayOnBus: json['stayOnBus'] ?? false,
    intermediateStops: (json['intermediateStops'] as List? ?? [])
        .map((s) => IntermediateStop.fromJson(s as Map<String, dynamic>))
        .toList(),
    alerts: (json['alerts'] as List? ?? [])
        .map((a) => AlertInfo(text: a.toString()))
        .toList(),
    serviceDate: json['serviceDate'] ?? '',
    patternCode: json['patternCode'] ?? '',
  );
}

class RouteSegment {
  final List<LatLng> points;
  final bool isWalk;

  RouteSegment({required this.points, required this.isWalk});

  Map<String, dynamic> toJson() {
    return {
      'points': points.map((p) {
        return {'lat': p.latitude, 'lon': p.longitude};
      }).toList(),
      'isWalk': isWalk,
    };
  }

  factory RouteSegment.fromJson(Map<String, dynamic> json) {
    final ptsList = json['points'] as List? ?? [];
    final decodedPoints = ptsList.map((p) {
      return LatLng((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble());
    }).toList();

    return RouteSegment(points: decodedPoints, isWalk: json['isWalk'] ?? false);
  }
}

class RouteOption {
  final DateTime leaveHomeTime;
  final DateTime arrivalTime;
  final List<BusLeg> busLegs;
  final List<RouteSegment> segments;
  final List<double> walkDistances;

  /// Kävelyjen kestot samoilla indekseillä kuin [walkDistances]: [i] on
  /// kävely ennen bussivaihetta i, viimeinen loppukävely. Voi puuttua
  /// vanhasta välimuistista (= tyhjä lista).
  final List<Duration> walkDurations;

  RouteOption({
    required this.leaveHomeTime,
    required this.arrivalTime,
    required this.busLegs,
    required this.segments,
    this.walkDistances = const [],
    this.walkDurations = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'leaveHomeTime': leaveHomeTime.millisecondsSinceEpoch,
      'arrivalTime': arrivalTime.millisecondsSinceEpoch,
      'walkDistances': walkDistances,
      'walkDurationsSec': walkDurations.map((d) => d.inSeconds).toList(),
      'busLegs': busLegs.map((l) {
        return l.toJson();
      }).toList(),
      'segments': segments.map((s) {
        return s.toJson();
      }).toList(),
    };
  }

  factory RouteOption.fromJson(Map<String, dynamic> json) {
    final rawBusLegs = json['busLegs'] as List? ?? [];
    final rawSegments = json['segments'] as List? ?? [];
    final rawWalks = json['walkDistances'] as List? ?? [];
    final rawWalkSecs = json['walkDurationsSec'] as List? ?? [];

    return RouteOption(
      leaveHomeTime: DateTime.fromMillisecondsSinceEpoch(
        json['leaveHomeTime'] ?? 0,
      ),
      arrivalTime: DateTime.fromMillisecondsSinceEpoch(
        json['arrivalTime'] ?? 0,
      ),
      walkDistances: List<double>.from(
        rawWalks.map((v) {
          return (v as num).toDouble();
        }),
      ),
      walkDurations: rawWalkSecs
          .map((v) => Duration(seconds: (v as num).toInt()))
          .toList(),
      busLegs: rawBusLegs.map((l) {
        return BusLeg.fromJson(l as Map<String, dynamic>);
      }).toList(),
      segments: rawSegments.map((s) {
        return RouteSegment.fromJson(s as Map<String, dynamic>);
      }).toList(),
    );
  }
}

class FavoriteRoute {
  final String destinationName;
  final double destLat;
  final double destLon;
  final String? startName;
  final double? startLat;
  final double? startLon;
  final int savedAtMs;

  FavoriteRoute({
    required this.destinationName,
    required this.destLat,
    required this.destLon,
    this.startName,
    this.startLat,
    this.startLon,
    required this.savedAtMs,
  });

  Map<String, dynamic> toJson() => {
    'destinationName': destinationName,
    'destLat': destLat,
    'destLon': destLon,
    'startName': startName,
    'startLat': startLat,
    'startLon': startLon,
    'savedAtMs': savedAtMs,
  };

  factory FavoriteRoute.fromJson(Map<String, dynamic> json) => FavoriteRoute(
    destinationName: json['destinationName'],
    destLat: (json['destLat'] as num).toDouble(),
    destLon: (json['destLon'] as num).toDouble(),
    startName: json['startName'],
    startLat: (json['startLat'] as num?)?.toDouble(),
    startLon: (json['startLon'] as num?)?.toDouble(),
    savedAtMs: json['savedAtMs'] ?? 0,
  );

  String get displayLabel {
    final dest = destinationName;
    if (startName != null) {
      return '$startName → $dest';
    }
    return '📍 → $dest';
  }

  /// Tunnistaa suosikin nimen JA koordinaattien perusteella, jotta kaksi
  /// samannimistä kohdetta (esim. kaksi K-Markettia) eivät mene sekaisin.
  /// Toleranssi ~50 m kattaa geokoodauksen pyöristyserot.
  bool isSameDestination(Place place) {
    return destinationName == place.name &&
        (destLat - place.lat).abs() < 0.0005 &&
        (destLon - place.lon).abs() < 0.0005;
  }
}
