import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pohjoisen_reitit/services/realtime_utils.dart';
import 'package:pohjoisen_reitit/services/transit_service.dart';

TransitService makeService(MockClient client) => TransitService(
  digitransitKey: 'test-key',
  walttiClientId: 'client-id',
  walttiClientSecret: 'client-secret',
  client: client,
);

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

/// Mock, joka vastaa plan-kyselyyn reittiehdotuksella ja
/// aikataululaajennuksen pysäkkikyselyyn aikataululla.
MockClient planClient({
  required Map<String, dynamic> plan,
  required Map<String, dynamic> timetable,
}) {
  return MockClient((request) async {
    final body = request.body;
    if (body.contains('plan(')) {
      return http.Response(json.encode({'data': plan}), 200,
          headers: _jsonHeaders);
    }
    return http.Response(json.encode({'data': timetable}), 200,
        headers: _jsonHeaders);
  });
}

Map<String, dynamic> busLegJson({
  required String tripId,
  required DateTime departure,
  required DateTime arrival,
  required String fromStopId,
  required String toStopId,
}) => {
  'mode': 'BUS',
  'startTime': departure.millisecondsSinceEpoch,
  'endTime': arrival.millisecondsSinceEpoch,
  'distance': 8000,
  'interlineWithPreviousLeg': false,
  'trip': {'gtfsId': tripId},
  'route': {'shortName': '20', 'gtfsId': 'OULU:20', 'alerts': []},
  'from': {
    'name': 'Lähtö',
    'lat': 65.01,
    'lon': 25.47,
    'stop': {'gtfsId': fromStopId},
  },
  'to': {
    'name': 'Määränpää',
    'lat': 65.06,
    'lon': 25.47,
    'stop': {'gtfsId': toStopId},
  },
  'legGeometry': null,
  'intermediateStops': [],
};

Map<String, dynamic> stoptimeJson({
  required String tripId,
  required int scheduledDeparture,
  required int serviceDay,
  int? realtimeDeparture,
  bool realtime = false,
}) => {
  'scheduledDeparture': scheduledDeparture,
  'realtimeDeparture': realtimeDeparture ?? scheduledDeparture,
  'realtimeState': realtime ? 'UPDATED' : 'SCHEDULED',
  'realtime': realtime,
  'serviceDay': serviceDay,
  'trip': {
    'gtfsId': tripId,
    'route': {'shortName': '20'},
  },
};

void main() {
  group('getAutocompleteSuggestions', () {
    test('enkoodaa erikoismerkit ja parsii tulokset', () async {
      late Uri capturedUrl;
      final client = MockClient((request) async {
        capturedUrl = request.url;
        return http.Response(
          json.encode({
            'features': [
              {
                'properties': {
                  'name': 'Kauppatori',
                  'label': 'Kauppatori, Oulu',
                },
                'geometry': {
                  'coordinates': [25.4651, 65.0121],
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final places = await makeService(
        client,
      ).getAutocompleteSuggestions('Tori & Halli #2');

      // Erikoismerkit (&, #, välilyönnit) eivät riko kyselyä, vaan
      // päätyvät enkoodattuina text-parametriin.
      expect(capturedUrl.queryParameters['text'], 'Tori & Halli #2');
      expect(capturedUrl.queryParameters['boundary.rect.min_lat'], '64.7');

      expect(places, hasLength(1));
      expect(places.single.name, 'Kauppatori');
      expect(places.single.label, 'Kauppatori, Oulu');
      expect(places.single.lat, 65.0121);
      expect(places.single.lon, 25.4651);
    });

    test('alle kahden merkin haku ei tee API-kutsua', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      });

      final places = await makeService(client).getAutocompleteSuggestions(' K ');

      expect(places, isEmpty);
      expect(called, isFalse);
    });

    test('HTTP-virhe palauttaa tyhjän listan kaatumatta', () async {
      final client = MockClient(
        (request) async => http.Response('error', 500),
      );

      final places = await makeService(
        client,
      ).getAutocompleteSuggestions('Kauppatori');

      expect(places, isEmpty);
    });
  });

  group('fetchStopDepartures', () {
    test('parsii lähdöt ja ohittaa puutteelliset rivit', () async {
      final client = MockClient((request) async {
        return http.Response(
          json.encode({
            'data': {
              'stop': {
                'stoptimesWithoutPatterns': [
                  {
                    'scheduledDeparture': 3600,
                    'realtimeDeparture': 3660,
                    'realtimeState': 'UPDATED',
                    'realtime': true,
                    'serviceDay': 1780000000,
                    'headsign': 'Keskusta',
                    'trip': {
                      'gtfsId': 'OULU:111',
                      'route': {'shortName': '20', 'gtfsId': 'OULU:20'},
                    },
                  },
                  // Rivi ilman aikatauludataa ohitetaan.
                  {
                    'scheduledDeparture': null,
                    'serviceDay': 1780000000,
                    'trip': {
                      'route': {'shortName': '30'},
                    },
                  },
                ],
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final departures = await makeService(
        client,
      ).fetchStopDepartures('OULU:201');

      expect(departures, hasLength(1));
      final dep = departures.single;
      expect(dep.busNumber, '20');
      expect(dep.headsign, 'Keskusta');
      expect(dep.tripId, 'OULU:111');
      expect(dep.routeGtfsId, 'OULU:20');
      expect(dep.scheduledEpochSec, 1780003600);
      expect(dep.realtimeEpochSec, 1780003660);
      expect(dep.isRealtime, isTrue);
    });

    test('heittää poikkeuksen HTTP-virheestä, jotta UI voi näyttää sen', () {
      final client = MockClient(
        (request) async => http.Response('error', 500),
      );

      expect(
        () => makeService(client).fetchStopDepartures('OULU:201'),
        throwsException,
      );
    });

    test('tyhjä stopId palauttaa tyhjän listan ilman API-kutsua', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      });

      final departures = await makeService(client).fetchStopDepartures('');

      expect(departures, isEmpty);
      expect(called, isFalse);
    });
  });

  group('fetchRoutes + aikataululaajennus', () {
    final dep = DateTime(2026, 6, 11, 12, 0);
    final serviceDay = DateTime(2026, 6, 11).millisecondsSinceEpoch ~/ 1000;
    const noonSecs = 12 * 3600;

    test('myöhässä olevan bussin viive ei kertaudu saapumisaikaan', () async {
      final arr = DateTime(2026, 6, 11, 12, 30);
      final plan = {
        'plan': {
          'itineraries': [
            {
              'startTime': dep.millisecondsSinceEpoch,
              'endTime': arr.millisecondsSinceEpoch,
              'legs': [
                busLegJson(
                  tripId: 'OULU:111',
                  departure: dep,
                  arrival: arr,
                  fromStopId: 'OULU:201',
                  toStopId: 'OULU:205',
                ),
              ],
            },
          ],
        },
      };
      final timetable = {
        'stop0': {
          'gtfsId': 'OULU:201',
          'stoptimesWithoutPatterns': [
            // Sama vuoro, 5 min myöhässä.
            stoptimeJson(
              tripId: 'OULU:111',
              scheduledDeparture: noonSecs,
              realtimeDeparture: noonSecs + 300,
              serviceDay: serviceDay,
              realtime: true,
            ),
          ],
        },
      };

      final options = await makeService(
        planClient(plan: plan, timetable: timetable),
      ).fetchRoutes(65.0, 25.4, 65.1, 25.5, dep, 120, 1.4);

      expect(options, hasLength(1));
      final option = options.single;
      final leg = option.busLegs.single;

      expect(leg.departureTime, dep);
      expect(leg.realtimeDeparture, dep.add(const Duration(minutes: 5)));
      expect(leg.isRealtime, isTrue);

      // Reitin saapumisaika pysyy aikataulussa…
      expect(option.arrivalTime, arr);
      // …ja näytettävä aika sisältää viiveen täsmälleen kerran.
      expect(
        realArrivalTime(option, null),
        arr.add(const Duration(minutes: 5)),
      );
    });

    test('kloonattujen lähtöjen jatkovaiheilta tyhjennetään vanha trip-id',
        () async {
      final leg1Arr = DateTime(2026, 6, 11, 12, 20);
      final leg2Dep = DateTime(2026, 6, 11, 12, 30);
      final leg2Arr = DateTime(2026, 6, 11, 12, 50);
      final plan = {
        'plan': {
          'itineraries': [
            {
              'startTime': dep.millisecondsSinceEpoch,
              'endTime': leg2Arr.millisecondsSinceEpoch,
              'legs': [
                busLegJson(
                  tripId: 'OULU:111',
                  departure: dep,
                  arrival: leg1Arr,
                  fromStopId: 'OULU:201',
                  toStopId: 'OULU:203',
                ),
                busLegJson(
                  tripId: 'OULU:222',
                  departure: leg2Dep,
                  arrival: leg2Arr,
                  fromStopId: 'OULU:204',
                  toStopId: 'OULU:205',
                ),
              ],
            },
          ],
        },
      };
      final timetable = {
        'stop0': {
          'gtfsId': 'OULU:201',
          'stoptimesWithoutPatterns': [
            // Alkuperäinen lähtö.
            stoptimeJson(
              tripId: 'OULU:111',
              scheduledDeparture: noonSecs,
              serviceDay: serviceDay,
            ),
            // Saman linjan seuraava vuoro 15 min myöhemmin.
            stoptimeJson(
              tripId: 'OULU:333',
              scheduledDeparture: noonSecs + 900,
              serviceDay: serviceDay,
            ),
          ],
        },
      };

      final options = await makeService(
        planClient(plan: plan, timetable: timetable),
      ).fetchRoutes(65.0, 25.4, 65.1, 25.5, dep, 120, 1.4);

      expect(options, hasLength(2));

      // Alkuperäinen lähtö: jatkovaiheen trip-id säilyy, jotta live-feed
      // osaa seurata oikeaa vaihtobussia.
      final original = options[0];
      expect(original.busLegs[0].tripId, 'OULU:111');
      expect(original.busLegs[1].tripId, 'OULU:222');

      // Myöhempi lähtö: jatkovaiheen trip-id tyhjennetään, koska se
      // kuvaisi alkuperäisen lähdön (väärää) vuoroa.
      final clone = options[1];
      expect(clone.busLegs[0].tripId, 'OULU:333');
      expect(clone.busLegs[1].tripId, isEmpty);
      expect(
        clone.busLegs[1].departureTime,
        leg2Dep.add(const Duration(minutes: 15)),
      );
      expect(clone.arrivalTime, leg2Arr.add(const Duration(minutes: 15)));
    });
  });

  group('fetchTripRealtime', () {
    test('parsii vain reaaliaikaiset pysäkit vuoroittain', () async {
      final serviceDay = DateTime(2026, 6, 11).millisecondsSinceEpoch ~/ 1000;
      final client = MockClient((request) async {
        return http.Response(
          json.encode({
            'data': {
              'trip0': {
                'gtfsId': 'OULU:111',
                'stoptimes': [
                  {
                    'stop': {'gtfsId': 'OULU:201'},
                    'realtimeArrival': 12 * 3600 + 240,
                    'realtimeDeparture': 12 * 3600 + 300,
                    'realtime': true,
                    'realtimeState': 'UPDATED',
                    'serviceDay': serviceDay,
                  },
                  // Pysäkki ilman oikeaa reaaliaikatietoa ohitetaan.
                  {
                    'stop': {'gtfsId': 'OULU:202'},
                    'realtimeArrival': 12 * 3600,
                    'realtimeDeparture': 12 * 3600,
                    'realtime': false,
                    'realtimeState': 'SCHEDULED',
                    'serviceDay': serviceDay,
                  },
                ],
              },
              'trip1': null,
            },
          }),
          200,
          headers: _jsonHeaders,
        );
      });

      final result = await makeService(
        client,
      ).fetchTripRealtime(['OULU:111', 'OULU:999']);

      expect(result, isNotNull);
      expect(result!.keys, ['OULU:111']);
      final byStop = result['OULU:111']!.byStopId;
      expect(byStop.keys, ['OULU:201']);
      expect(byStop['OULU:201']!.departure, DateTime(2026, 6, 11, 12, 5));
      expect(byStop['OULU:201']!.arrival, DateTime(2026, 6, 11, 12, 4));
      expect(byStop['OULU:201']!.realtimeState, 'UPDATED');
    });

    test('palauttaa null virheestä, jotta vanha data säilyy', () async {
      final client = MockClient(
        (request) async => http.Response('error', 500),
      );

      expect(await makeService(client).fetchTripRealtime(['OULU:111']), isNull);
    });

    test('tyhjä vuorolista palautuu ilman API-kutsua', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      });

      final result = await makeService(client).fetchTripRealtime([]);

      expect(result, isEmpty);
      expect(called, isFalse);
    });
  });

  group('fetchNearbyStops', () {
    test('palauttaa tyhjän listan virheestä kaatumatta', () async {
      final client = MockClient(
        (request) async => http.Response('error', 500),
      );

      final stops = await makeService(
        client,
      ).fetchNearbyStops(64.9, 25.3, 65.1, 25.6);

      expect(stops, isEmpty);
    });

    test('parsii pysäkit vastauksesta', () async {
      final client = MockClient((request) async {
        return http.Response(
          json.encode({
            'data': {
              'stopsByBbox': [
                {
                  'gtfsId': 'OULU:201',
                  'name': 'Tori',
                  'lat': 65.01,
                  'lon': 25.47,
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final stops = await makeService(
        client,
      ).fetchNearbyStops(64.9, 25.3, 65.1, 25.6);

      expect(stops, hasLength(1));
      expect(stops.single['gtfsId'], 'OULU:201');
      expect(stops.single['name'], 'Tori');
    });
  });
}
