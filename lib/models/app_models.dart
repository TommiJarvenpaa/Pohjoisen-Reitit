import 'package:latlong2/latlong.dart';

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
  AlertInfo({required this.text});
}

class IntermediateStop {
  final String name;
  final double lat;
  final double lon;

  IntermediateStop({required this.name, required this.lat, required this.lon});

  Map<String, dynamic> toJson() => {'name': name, 'lat': lat, 'lon': lon};

  factory IntermediateStop.fromJson(Map<String, dynamic> json) =>
      IntermediateStop(
        name: json['name'] ?? '',
        lat: (json['lat'] as num).toDouble(),
        lon: (json['lon'] as num).toDouble(),
      );
}

class StopTimeData {
  final int scheduledEpochSec;
  final int realtimeEpochSec;
  final String realtimeState;
  final bool isRealtime;
  final String? busNumber;
  final String? headsign;

  StopTimeData({
    required this.scheduledEpochSec,
    required this.realtimeEpochSec,
    required this.realtimeState,
    required this.isRealtime,
    this.busNumber,
    this.headsign,
  });
}

class BusLeg {
  final String busNumber;
  final String routeGtfsId;
  final String fromStop;
  final String fromStopId;
  final double? fromLat;
  final double? fromLon;
  final String toStop;
  final double? toLat;
  final double? toLon;
  final DateTime departureTime;
  final DateTime arrivalTime;
  final DateTime realtimeDeparture;
  final String realtimeState;
  final bool isRealtime;
  final List<IntermediateStop> intermediateStops;
  final List<AlertInfo> alerts;

  BusLeg({
    required this.busNumber,
    this.routeGtfsId = '',
    required this.fromStop,
    required this.fromStopId,
    this.fromLat,
    this.fromLon,
    required this.toStop,
    this.toLat,
    this.toLon,
    required this.departureTime,
    required this.arrivalTime,
    required this.realtimeDeparture,
    required this.realtimeState,
    required this.isRealtime,
    this.intermediateStops = const [],
    this.alerts = const [],
  });

  Map<String, dynamic> toJson() => {
    'busNumber': busNumber,
    'routeGtfsId': routeGtfsId,
    'fromStop': fromStop,
    'fromStopId': fromStopId,
    'fromLat': fromLat,
    'fromLon': fromLon,
    'toStop': toStop,
    'toLat': toLat,
    'toLon': toLon,
    'departureTime': departureTime.millisecondsSinceEpoch,
    'arrivalTime': arrivalTime.millisecondsSinceEpoch,
    'realtimeDeparture': realtimeDeparture.millisecondsSinceEpoch,
    'realtimeState': realtimeState,
    'isRealtime': isRealtime,
    'intermediateStops': intermediateStops.map((s) => s.toJson()).toList(),
    'alerts': alerts.map((a) => a.text).toList(),
  };

  factory BusLeg.fromJson(Map<String, dynamic> json) => BusLeg(
    busNumber: json['busNumber'] ?? '',
    routeGtfsId: json['routeGtfsId'] ?? '',
    fromStop: json['fromStop'] ?? '',
    fromStopId: json['fromStopId'] ?? '',
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
    realtimeState: json['realtimeState'] ?? 'SCHEDULED',
    isRealtime: json['isRealtime'] ?? false,
    intermediateStops: (json['intermediateStops'] as List? ?? [])
        .map((s) => IntermediateStop.fromJson(s as Map<String, dynamic>))
        .toList(),
    alerts: (json['alerts'] as List? ?? [])
        .map((a) => AlertInfo(text: a.toString()))
        .toList(),
  );
}

class RouteSegment {
  final List<LatLng> points;
  final bool isWalk;
  RouteSegment({required this.points, required this.isWalk});
}

class RouteOption {
  final DateTime leaveHomeTime;
  final DateTime arrivalTime;
  final List<BusLeg> busLegs;
  final List<RouteSegment> segments;
  final List<double> walkDistances;

  RouteOption({
    required this.leaveHomeTime,
    required this.arrivalTime,
    required this.busLegs,
    required this.segments,
    this.walkDistances = const [],
  });

  Map<String, dynamic> toJson() => {
    'leaveHomeTime': leaveHomeTime.millisecondsSinceEpoch,
    'arrivalTime': arrivalTime.millisecondsSinceEpoch,
    'walkDistances': walkDistances,
    'busLegs': busLegs.map((l) => l.toJson()).toList(),
  };

  factory RouteOption.fromJson(Map<String, dynamic> json) => RouteOption(
    leaveHomeTime: DateTime.fromMillisecondsSinceEpoch(
      json['leaveHomeTime'] ?? 0,
    ),
    arrivalTime: DateTime.fromMillisecondsSinceEpoch(json['arrivalTime'] ?? 0),
    walkDistances: List<double>.from(
      (json['walkDistances'] as List? ?? []).map((v) => (v as num).toDouble()),
    ),
    busLegs: (json['busLegs'] as List? ?? [])
        .map((l) => BusLeg.fromJson(l as Map<String, dynamic>))
        .toList(),
    segments: [],
  );
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
    if (startName != null) return '$startName → $dest';
    return '📍 → $dest';
  }
}
