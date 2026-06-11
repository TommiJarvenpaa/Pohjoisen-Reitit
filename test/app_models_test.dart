import 'package:flutter_test/flutter_test.dart';
import 'package:pohjoisen_reitit/models/app_models.dart';

BusLeg makeLeg() => BusLeg(
  busNumber: '20',
  routeGtfsId: 'OULU:20',
  tripId: 'OULU:111_20260611',
  fromStop: 'Tori',
  fromStopId: 'OULU:201',
  toStopId: 'OULU:205',
  legStopIds: const ['OULU:201', 'OULU:202', 'OULU:205'],
  fromLat: 65.01,
  fromLon: 25.47,
  toStop: 'Yliopisto',
  toLat: 65.06,
  toLon: 25.47,
  departureTime: DateTime(2026, 6, 11, 12, 0),
  arrivalTime: DateTime(2026, 6, 11, 12, 30),
  realtimeDeparture: DateTime(2026, 6, 11, 12, 2),
  realtimeState: 'UPDATED',
  isRealtime: true,
  stayOnBus: true,
  intermediateStops: [
    IntermediateStop(name: 'Kauppuri', lat: 65.02, lon: 25.47, gtfsId: 'OULU:202'),
  ],
  alerts: [AlertInfo(text: 'Poikkeusreitti')],
);

void main() {
  group('BusLeg', () {
    test('toJson/fromJson säilyttää kentät', () {
      final leg = makeLeg();
      final restored = BusLeg.fromJson(leg.toJson());

      expect(restored.busNumber, leg.busNumber);
      expect(restored.routeGtfsId, leg.routeGtfsId);
      expect(restored.tripId, leg.tripId);
      expect(restored.legStopIds, leg.legStopIds);
      expect(restored.departureTime, leg.departureTime);
      expect(restored.arrivalTime, leg.arrivalTime);
      expect(restored.realtimeDeparture, leg.realtimeDeparture);
      expect(restored.realtimeState, leg.realtimeState);
      expect(restored.isRealtime, leg.isRealtime);
      expect(restored.stayOnBus, leg.stayOnBus);
      expect(restored.intermediateStops.single.name, 'Kauppuri');
      expect(restored.intermediateStops.single.gtfsId, 'OULU:202');
      expect(restored.alerts.single.text, 'Poikkeusreitti');
    });

    test('fromJson sietää sekalaiset legStopIds-arvot', () {
      final json = makeLeg().toJson();
      json['legStopIds'] = [1, 'OULU:202', null];

      final restored = BusLeg.fromJson(json);

      expect(restored.legStopIds, ['1', 'OULU:202', '']);
    });

    test('copyWith muuttaa vain annetut kentät', () {
      final leg = makeLeg();
      final newDeparture = DateTime(2026, 6, 11, 13, 0);

      final copy = leg.copyWith(
        tripId: 'OULU:999_20260611',
        departureTime: newDeparture,
        isRealtime: false,
      );

      expect(copy.tripId, 'OULU:999_20260611');
      expect(copy.departureTime, newDeparture);
      expect(copy.isRealtime, isFalse);
      // Muut kentät säilyvät.
      expect(copy.busNumber, leg.busNumber);
      expect(copy.arrivalTime, leg.arrivalTime);
      expect(copy.legStopIds, leg.legStopIds);
      expect(copy.stayOnBus, leg.stayOnBus);
      expect(copy.alerts, leg.alerts);
    });
  });

  group('RouteOption', () {
    test('toJson/fromJson säilyttää reitin', () {
      final option = RouteOption(
        leaveHomeTime: DateTime(2026, 6, 11, 11, 50),
        arrivalTime: DateTime(2026, 6, 11, 12, 35),
        busLegs: [makeLeg()],
        segments: [
          RouteSegment(points: const [], isWalk: true),
        ],
        walkDistances: const [120.0, 80.0],
      );

      final restored = RouteOption.fromJson(option.toJson());

      expect(restored.leaveHomeTime, option.leaveHomeTime);
      expect(restored.arrivalTime, option.arrivalTime);
      expect(restored.busLegs.single.busNumber, '20');
      expect(restored.walkDistances, [120.0, 80.0]);
    });

    test('fromJson sietää puuttuvat kentät (vanha välimuisti)', () {
      final restored = RouteOption.fromJson({
        'leaveHomeTime': DateTime(2026, 6, 11, 12, 0).millisecondsSinceEpoch,
        'arrivalTime': DateTime(2026, 6, 11, 12, 30).millisecondsSinceEpoch,
      });

      expect(restored.busLegs, isEmpty);
      expect(restored.segments, isEmpty);
      expect(restored.walkDistances, isEmpty);
    });
  });

  group('FavoriteRoute.isSameDestination', () {
    final favorite = FavoriteRoute(
      destinationName: 'K-Market',
      destLat: 65.0100,
      destLon: 25.4700,
      savedAtMs: 0,
    );

    test('sama nimi ja lähes samat koordinaatit täsmäävät', () {
      expect(
        favorite.isSameDestination(
          Place(name: 'K-Market', lat: 65.0101, lon: 25.4701),
        ),
        isTrue,
      );
    });

    test('samanniminen kohde eri paikassa ei täsmää', () {
      expect(
        favorite.isSameDestination(
          Place(name: 'K-Market', lat: 65.0500, lon: 25.5200),
        ),
        isFalse,
      );
    });

    test('eri nimi ei täsmää', () {
      expect(
        favorite.isSameDestination(
          Place(name: 'S-Market', lat: 65.0100, lon: 25.4700),
        ),
        isFalse,
      );
    });
  });

  group('Place', () {
    test('toJson/fromJson säilyttää kentät', () {
      final place = Place(
        name: 'Kauppatori',
        lat: 65.0121,
        lon: 25.4651,
        label: 'Kauppatori, Oulu',
      );

      final restored = Place.fromJson(place.toJson());

      expect(restored.name, place.name);
      expect(restored.lat, place.lat);
      expect(restored.lon, place.lon);
      expect(restored.label, place.label);
    });
  });
}
