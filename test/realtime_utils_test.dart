import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:pohjoisen_reitit/models/app_models.dart';
import 'package:pohjoisen_reitit/services/realtime_utils.dart';

BusLeg makeLeg({
  String tripId = 'OULU:111_20260611',
  String routeGtfsId = 'OULU:20',
  String busNumber = '20',
  String fromStopId = 'OULU:201',
  String toStopId = 'OULU:205',
  List<String> legStopIds = const ['OULU:201', 'OULU:202', 'OULU:205'],
  DateTime? departureTime,
  DateTime? realtimeDeparture,
  bool isRealtime = false,
  List<IntermediateStop> intermediateStops = const [],
  double? fromLat,
  double? fromLon,
  double? toLat,
  double? toLon,
}) {
  final dep = departureTime ?? DateTime(2026, 6, 11, 12, 0);
  return BusLeg(
    busNumber: busNumber,
    routeGtfsId: routeGtfsId,
    tripId: tripId,
    fromStop: 'Lähtöpysäkki',
    fromStopId: fromStopId,
    toStopId: toStopId,
    legStopIds: legStopIds,
    fromLat: fromLat,
    fromLon: fromLon,
    toStop: 'Päätepysäkki',
    toLat: toLat,
    toLon: toLon,
    departureTime: dep,
    arrivalTime: dep.add(const Duration(minutes: 30)),
    realtimeDeparture: realtimeDeparture ?? dep,
    realtimeState: 'SCHEDULED',
    isRealtime: isRealtime,
    intermediateStops: intermediateStops,
  );
}

FeedMessage tripUpdateFeed({
  required String tripId,
  required String stopId,
  int? departureEpochSec,
  int? arrivalEpochSec,
}) {
  return FeedMessage(
    entity: [
      FeedEntity(
        id: '1',
        tripUpdate: TripUpdate(
          trip: TripDescriptor(tripId: tripId),
          stopTimeUpdate: [
            TripUpdate_StopTimeUpdate(
              stopId: stopId,
              departure: departureEpochSec != null
                  ? TripUpdate_StopTimeEvent(time: Int64(departureEpochSec))
                  : null,
              arrival: arrivalEpochSec != null
                  ? TripUpdate_StopTimeEvent(time: Int64(arrivalEpochSec))
                  : null,
            ),
          ],
        ),
      ),
    ],
  );
}

void main() {
  group('tripIdMatches', () {
    test('täysin sama id täsmää', () {
      expect(tripIdMatches('OULU:111_20260611', 'OULU:111_20260611'), isTrue);
    });

    test('namespace- ja päivämääräerot eivät estä täsmäystä', () {
      expect(tripIdMatches('waltti:111_20260611', 'OULU:111_20260612'), isTrue);
      expect(tripIdMatches('111', 'OULU:111_20260611'), isTrue);
    });

    test('osittainen numero-osuma ei täsmää', () {
      expect(tripIdMatches('100123456', '1001234567'), isFalse);
    });
  });

  group('getRealtimeStopTime / getRealtimeArrivalTime', () {
    const depSec = 1781000000;
    const arrSec = 1780999940;

    test('palauttaa lähtöajan kun feedissä on molemmat ajat', () {
      final feed = tripUpdateFeed(
        tripId: 'waltti:111_20260611',
        stopId: '202',
        departureEpochSec: depSec,
        arrivalEpochSec: arrSec,
      );
      final leg = makeLeg();

      expect(
        getRealtimeStopTime(feed, leg, 'OULU:202'),
        DateTime.fromMillisecondsSinceEpoch(depSec * 1000),
      );
      expect(
        getRealtimeArrivalTime(feed, leg, 'OULU:202'),
        DateTime.fromMillisecondsSinceEpoch(arrSec * 1000),
      );
    });

    test('käyttää toista aikaa kun ensisijainen puuttuu', () {
      final feed = tripUpdateFeed(
        tripId: 'waltti:111_20260611',
        stopId: '202',
        departureEpochSec: depSec,
      );
      final leg = makeLeg();

      // Saapumisaikaa ei ole, joten palautuu lähtöaika.
      expect(
        getRealtimeArrivalTime(feed, leg, 'OULU:202'),
        DateTime.fromMillisecondsSinceEpoch(depSec * 1000),
      );
    });

    test('palauttaa null kun pysäkki tai trip ei täsmää', () {
      final feed = tripUpdateFeed(
        tripId: 'waltti:999_20260611',
        stopId: '202',
        departureEpochSec: depSec,
      );
      final leg = makeLeg();

      expect(getRealtimeStopTime(feed, leg, 'OULU:202'), isNull);

      final feed2 = tripUpdateFeed(
        tripId: 'waltti:111_20260611',
        stopId: '777',
        departureEpochSec: depSec,
      );
      expect(getRealtimeStopTime(feed2, leg, 'OULU:202'), isNull);
    });

    test('palauttaa null ilman feediä tai trip-id:tä', () {
      expect(getRealtimeStopTime(null, makeLeg(), 'OULU:202'), isNull);
      expect(
        getRealtimeStopTime(
          tripUpdateFeed(
            tripId: 'x',
            stopId: '202',
            departureEpochSec: depSec,
          ),
          makeLeg(tripId: ''),
          'OULU:202',
        ),
        isNull,
      );
    });
  });

  group('getRealtimeCurrentStopIndex', () {
    test('löytää pysäkin vehicle.stopId:n perusteella', () {
      final feed = FeedMessage(
        entity: [
          FeedEntity(
            id: 'v1',
            vehicle: VehiclePosition(
              trip: TripDescriptor(
                tripId: 'waltti:111_20260611',
                routeId: 'OULU:20',
              ),
              stopId: '202',
            ),
          ),
        ],
      );

      expect(getRealtimeCurrentStopIndex(feed, makeLeg()), 1);
    });

    test('arvioi pysäkin sijainnista kun stopId puuttuu', () {
      final feed = FeedMessage(
        entity: [
          FeedEntity(
            id: 'v1',
            vehicle: VehiclePosition(
              trip: TripDescriptor(
                tripId: 'waltti:111_20260611',
                routeId: 'OULU:20',
              ),
              position: Position(latitude: 65.010, longitude: 25.420),
            ),
          ),
        ],
      );
      final leg = makeLeg(
        fromLat: 65.000,
        fromLon: 25.400,
        toLat: 65.020,
        toLon: 25.440,
        intermediateStops: [
          IntermediateStop(name: 'Keskipysäkki', lat: 65.010, lon: 25.420),
        ],
      );

      // Bussi on täsmälleen välipysäkillä: indeksi 1 (from=0, väli=1, to=2).
      expect(getRealtimeCurrentStopIndex(feed, leg), 1);
    });

    test('palauttaa null kun linja ei täsmää', () {
      final feed = FeedMessage(
        entity: [
          FeedEntity(
            id: 'v1',
            vehicle: VehiclePosition(
              trip: TripDescriptor(
                tripId: 'waltti:111_20260611',
                routeId: 'OULU:99',
              ),
              stopId: '202',
            ),
          ),
        ],
      );

      expect(getRealtimeCurrentStopIndex(feed, makeLeg()), isNull);
    });
  });

  group('transferLatenessMinutes', () {
    test('myöhässä oleva bussi tuottaa positiivisen arvon', () {
      // Edellinen vaihe 5 min myöhässä: saapuu 12:35, seuraava lähtee 12:33.
      final prev = makeLeg(
        departureTime: DateTime(2026, 6, 11, 12, 0),
        realtimeDeparture: DateTime(2026, 6, 11, 12, 5),
        isRealtime: true,
      );
      final next = makeLeg(
        tripId: 'OULU:222_20260611',
        departureTime: DateTime(2026, 6, 11, 12, 33),
        realtimeDeparture: DateTime(2026, 6, 11, 12, 33),
      );

      expect(transferLatenessMinutes(prev, next, null), 2);
    });

    test('ajallaan oleva vaihto tuottaa negatiivisen arvon', () {
      final prev = makeLeg(); // saapuu 12:30
      final next = makeLeg(
        tripId: 'OULU:222_20260611',
        departureTime: DateTime(2026, 6, 11, 12, 40),
        realtimeDeparture: DateTime(2026, 6, 11, 12, 40),
      );

      expect(transferLatenessMinutes(prev, next, null), -10);
    });
  });

  group('realArrivalTime', () {
    RouteOption makeOption(BusLeg leg) => RouteOption(
      leaveHomeTime: DateTime(2026, 6, 11, 11, 55),
      // Bussi perillä 12:30 + 10 min loppukävely.
      arrivalTime: DateTime(2026, 6, 11, 12, 40),
      busLegs: [leg],
      segments: [],
    );

    test('yhden bussin reitillä viive lasketaan vain kerran', () {
      final leg = makeLeg(
        realtimeDeparture: DateTime(2026, 6, 11, 12, 5),
        isRealtime: true,
      );

      // 12:30 + 5 min viive + 10 min kävely = 12:45 (ei 12:50).
      expect(
        realArrivalTime(makeOption(leg), null),
        DateTime(2026, 6, 11, 12, 45),
      );
    });

    test('feedin tarkka saapumisaika ohittaa arvion', () {
      final leg = makeLeg(
        realtimeDeparture: DateTime(2026, 6, 11, 12, 5),
        isRealtime: true,
      );
      final arrivalSec =
          DateTime(2026, 6, 11, 12, 37).millisecondsSinceEpoch ~/ 1000;
      final feed = tripUpdateFeed(
        tripId: 'waltti:111_20260611',
        stopId: '205',
        arrivalEpochSec: arrivalSec,
      );

      // 12:37 (feed) + 10 min kävely = 12:47.
      expect(
        realArrivalTime(makeOption(leg), feed),
        DateTime(2026, 6, 11, 12, 47),
      );
    });

    test('kävelyreitillä palautuu reitin oma saapumisaika', () {
      final option = RouteOption(
        leaveHomeTime: DateTime(2026, 6, 11, 12, 0),
        arrivalTime: DateTime(2026, 6, 11, 12, 25),
        busLegs: const [],
        segments: const [],
      );

      expect(realArrivalTime(option, null), DateTime(2026, 6, 11, 12, 25));
    });
  });

  group('intermediateStopTimeLabel', () {
    String fmt(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    test('arvioi ajan lineaarisesti ilman feediä', () {
      // 30 min matka, 2 välipysäkkiä -> kolmasosa per väli.
      final leg = makeLeg(
        intermediateStops: [
          IntermediateStop(name: 'A', lat: 0, lon: 0),
          IntermediateStop(name: 'B', lat: 0, lon: 0),
        ],
      );

      expect(intermediateStopTimeLabel(0, leg, null, fmt), '12:10');
      expect(intermediateStopTimeLabel(1, leg, null, fmt), '12:20');
    });

    test('lisää viiveen arvioon kun matka on myöhässä', () {
      final leg = makeLeg(
        realtimeDeparture: DateTime(2026, 6, 11, 12, 5),
        isRealtime: true,
        intermediateStops: [
          IntermediateStop(name: 'A', lat: 0, lon: 0),
          IntermediateStop(name: 'B', lat: 0, lon: 0),
        ],
      );

      expect(intermediateStopTimeLabel(0, leg, null, fmt), '12:15');
    });
  });
}
