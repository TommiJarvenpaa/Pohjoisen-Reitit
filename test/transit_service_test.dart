import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pohjoisen_reitit/models/app_models.dart';
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

const _pattern20 = 'OULU:20:0:01';

/// OTP:n plan-vaihe. [departure]/[arrival] ovat aikataulun mukaiset ajat;
/// kuten oikea OTP, startTime/endTime sisältävät viiveen ja
/// departureDelay/arrivalDelay kertovat sen erikseen.
Map<String, dynamic> busLegJson({
  required String tripId,
  required DateTime departure,
  required DateTime arrival,
  required String fromStopId,
  required String toStopId,
  int departureDelaySec = 0,
  int arrivalDelaySec = 0,
  bool realTime = false,
  String patternCode = _pattern20,
  // Digitransitin oikea muoto (dokumentaatiosta poiketen väliviivoin).
  String serviceDate = '2026-06-11',
  List<Map<String, dynamic>> alerts = const [],
}) => {
  'mode': 'BUS',
  'startTime': departure
      .add(Duration(seconds: departureDelaySec))
      .millisecondsSinceEpoch,
  'endTime': arrival.add(Duration(seconds: arrivalDelaySec)).millisecondsSinceEpoch,
  'distance': 8000,
  'departureDelay': departureDelaySec,
  'arrivalDelay': arrivalDelaySec,
  'realTime': realTime,
  'realtimeState': realTime ? 'UPDATED' : 'SCHEDULED',
  'serviceDate': serviceDate,
  'interlineWithPreviousLeg': false,
  'trip': {
    'gtfsId': tripId,
    'pattern': {'code': patternCode},
  },
  'route': {'shortName': '20', 'gtfsId': 'OULU:20'},
  'alerts': alerts,
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

Map<String, dynamic> walkLegJson({
  required DateTime start,
  required Duration duration,
  double distance = 250,
}) => {
  'mode': 'WALK',
  'startTime': start.millisecondsSinceEpoch,
  'endTime': start.add(duration).millisecondsSinceEpoch,
  'distance': distance,
  'legGeometry': null,
};

Map<String, dynamic> stoptimeJson({
  required String tripId,
  required int scheduledDeparture,
  required int serviceDay,
  int? realtimeDeparture,
  bool realtime = false,
  String patternCode = _pattern20,
}) => {
  'scheduledDeparture': scheduledDeparture,
  'realtimeDeparture': realtimeDeparture ?? scheduledDeparture,
  'realtimeState': realtime ? 'UPDATED' : 'SCHEDULED',
  'realtime': realtime,
  'serviceDay': serviceDay,
  'trip': {
    'gtfsId': tripId,
    'pattern': {'code': patternCode},
    'route': {'shortName': '20'},
  },
};

Map<String, dynamic> planJson(List<Map<String, dynamic>> itineraries) => {
  'plan': {'itineraries': itineraries},
};

/// Itinerary, jonka start/end lasketaan vaiheista kuten OTP:ssä
/// (sisältävät viiveen).
Map<String, dynamic> itineraryJson(List<Map<String, dynamic>> legs) => {
  'startTime': legs.first['startTime'],
  'endTime': legs.last['endTime'],
  'legs': legs,
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
    test('pyytää myös perutut lähdöt ja tunnistaa ne', () async {
      late String body;
      final client = MockClient((request) async {
        body = request.body;
        return http.Response(
          json.encode({
            'data': {
              'stop': {
                'stoptimesWithoutPatterns': [
                  {
                    'scheduledDeparture': 3600,
                    'realtimeDeparture': 3600,
                    'realtimeState': 'CANCELED',
                    'realtime': true,
                    'serviceDay': 1780000000,
                    'headsign': 'Keskusta',
                    'trip': {
                      'gtfsId': 'OULU:111',
                      'route': {'shortName': '20K', 'gtfsId': 'OULU:20K'},
                    },
                  },
                ],
              },
            },
          }),
          200,
          headers: _jsonHeaders,
        );
      });

      final departures = await makeService(
        client,
      ).fetchStopDepartures('OULU:201');

      expect(body, contains('omitCanceled: false'));
      expect(departures.single.isCanceled, isTrue);
    });

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
      // OTP:n startTime/endTime sisältävät 5 min viiveen.
      final plan = planJson([
        itineraryJson([
          busLegJson(
            tripId: 'OULU:111',
            departure: dep,
            arrival: arr,
            fromStopId: 'OULU:201',
            toStopId: 'OULU:205',
            departureDelaySec: 300,
            arrivalDelaySec: 300,
            realTime: true,
          ),
        ]),
      ]);
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

      // Aikataulu = startTime - departureDelay.
      expect(leg.departureTime, dep);
      expect(leg.arrivalTime, arr);
      expect(leg.realtimeDeparture, dep.add(const Duration(minutes: 5)));
      expect(leg.isRealtime, isTrue);
      expect(leg.serviceDate, '20260611');
      expect(leg.patternCode, _pattern20);

      // Reitin lähtö- ja saapumisaika pysyvät aikataulussa…
      expect(option.leaveHomeTime, dep);
      expect(option.arrivalTime, arr);
      // …ja näytettävä aika sisältää viiveen täsmälleen kerran.
      expect(
        realArrivalTime(option, null),
        arr.add(const Duration(minutes: 5)),
      );
    });

    test('ensimmäisen bussin viive ei siirrä vaihtobussin aikoja', () async {
      final leg1Arr = DateTime(2026, 6, 11, 12, 20);
      final leg2Dep = DateTime(2026, 6, 11, 12, 30);
      final leg2Arr = DateTime(2026, 6, 11, 12, 50);
      // Ensimmäinen bussi 5 min myöhässä, vaihtobussi ajallaan.
      final plan = planJson([
        itineraryJson([
          busLegJson(
            tripId: 'OULU:111',
            departure: dep,
            arrival: leg1Arr,
            fromStopId: 'OULU:201',
            toStopId: 'OULU:203',
            departureDelaySec: 300,
            arrivalDelaySec: 300,
            realTime: true,
          ),
          busLegJson(
            tripId: 'OULU:222',
            departure: leg2Dep,
            arrival: leg2Arr,
            fromStopId: 'OULU:203',
            toStopId: 'OULU:205',
            realTime: true,
          ),
        ]),
      ]);
      final timetable = {
        'stop0': {
          'gtfsId': 'OULU:201',
          'stoptimesWithoutPatterns': [
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
      final legs = options.single.busLegs;
      // Vaihtobussi pysyy aikataulussaan (aiemmin se siirtyi 5 min aiemmaksi).
      expect(legs[1].departureTime, leg2Dep);
      expect(legs[1].realtimeDeparture, leg2Dep);
      expect(legs[1].tripId, 'OULU:222');
      expect(options.single.leaveHomeTime, dep);
      expect(options.single.arrivalTime, leg2Arr);
      // Saapuu 12:25, vaihto lähtee 12:30: 5 min vaihtoaikaa.
      expect(transferLatenessMinutes(legs[0], legs[1], null), -5);
    });

    test('vaihdollista reittiä ei kopioida keksittyihin vaihtoaikoihin',
        () async {
      final leg1Arr = DateTime(2026, 6, 11, 12, 20);
      final leg2Dep = DateTime(2026, 6, 11, 12, 30);
      final leg2Arr = DateTime(2026, 6, 11, 12, 50);
      final plan = planJson([
        itineraryJson([
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
        ]),
      ]);
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

      // Kopiossa vaihtobussi kulkisi 12:45, jota ei välttämättä ole
      // olemassa – vaihtoreitin vaihtoehdot tulevat vain OTP:ltä.
      expect(options, hasLength(1));
      final original = options.single;
      // Jatkovaiheen trip-id säilyy, jotta live-tieto löytää vaihtobussin.
      expect(original.busLegs[0].tripId, 'OULU:111');
      expect(original.busLegs[1].tripId, 'OULU:222');
      expect(original.busLegs[1].departureTime, leg2Dep);
    });

    test('kopioitu lähtö saa oman vuoron, päivän ja lähtöviiveen', () async {
      final arr = DateTime(2026, 6, 11, 12, 30);
      final plan = planJson([
        itineraryJson([
          busLegJson(
            tripId: 'OULU:111',
            departure: dep,
            arrival: arr,
            fromStopId: 'OULU:201',
            toStopId: 'OULU:205',
            departureDelaySec: 60,
            arrivalDelaySec: 240,
            realTime: true,
            alerts: [
              // Vuorokohtainen tiedote koskee vain pohjavuoroa.
              {
                'alertHeaderText': 'Vuoro 111 ajaa poikkeusreittiä',
                'effectiveStartDate': null,
                'effectiveEndDate': null,
                'trip': {'gtfsId': 'OULU:111'},
              },
              {
                'alertHeaderText': 'Pysäkki siirretty',
                'effectiveStartDate': null,
                'effectiveEndDate': null,
                'trip': null,
              },
            ],
          ),
        ]),
      ]);
      final timetable = {
        'stop0': {
          'gtfsId': 'OULU:201',
          'stoptimesWithoutPatterns': [
            stoptimeJson(
              tripId: 'OULU:111',
              scheduledDeparture: noonSecs,
              realtimeDeparture: noonSecs + 60,
              serviceDay: serviceDay,
              realtime: true,
            ),
            stoptimeJson(
              tripId: 'OULU:333',
              scheduledDeparture: noonSecs + 900,
              realtimeDeparture: noonSecs + 1020,
              serviceDay: serviceDay,
              realtime: true,
            ),
          ],
        },
      };

      final options = await makeService(
        planClient(plan: plan, timetable: timetable),
      ).fetchRoutes(65.0, 25.4, 65.1, 25.5, dep, 120, 1.4);

      expect(options, hasLength(2));
      final clone = options[1].busLegs.single;
      expect(clone.tripId, 'OULU:333');
      expect(clone.serviceDate, '20260611');
      expect(clone.departureTime, dep.add(const Duration(minutes: 15)));
      expect(clone.realtimeDeparture, dep.add(const Duration(minutes: 17)));
      // Pohjavuoron saapumisennuste ei koske kopiota: saapuminen arvioidaan
      // kopion omasta lähtöviiveestä.
      expect(clone.realtimeArrival, isNull);
      expect(
        displayedLegArrival(clone, null),
        arr.add(const Duration(minutes: 17)),
      );
      expect(clone.alerts.map((a) => a.text), ['Pysäkki siirretty']);
    });

    test('lähtöä, jolle ei ehdi kävellä, ei kopioida', () async {
      final walkStart = dep.subtract(const Duration(minutes: 10));
      final busDep = dep;
      final plan = planJson([
        itineraryJson([
          walkLegJson(start: walkStart, duration: const Duration(minutes: 10)),
          busLegJson(
            tripId: 'OULU:111',
            departure: busDep,
            arrival: DateTime(2026, 6, 11, 12, 30),
            fromStopId: 'OULU:201',
            toStopId: 'OULU:205',
          ),
        ]),
      ]);
      final timetable = {
        'stop0': {
          'gtfsId': 'OULU:201',
          'stoptimesWithoutPatterns': [
            // Lähtee 5 min hakuajan jälkeen, mutta kävely kestää 10 min.
            stoptimeJson(
              tripId: 'OULU:000',
              scheduledDeparture: noonSecs - 600 + 300,
              serviceDay: serviceDay,
            ),
            stoptimeJson(
              tripId: 'OULU:111',
              scheduledDeparture: noonSecs,
              serviceDay: serviceDay,
            ),
          ],
        },
      };
      // Haku klo 11:50: 11:55 lähtöön ei ehdi.
      final searchTime = dep.subtract(const Duration(minutes: 10));

      final options = await makeService(
        planClient(plan: plan, timetable: timetable),
      ).fetchRoutes(65.0, 25.4, 65.1, 25.5, searchTime, 120, 1.4);

      expect(options.map((o) => o.busLegs.single.tripId), ['OULU:111']);
    });

    test('eri poistumispysäkin pohjista ei synny tuplakortteja', () async {
      final plan = planJson([
        itineraryJson([
          busLegJson(
            tripId: 'OULU:111',
            departure: dep,
            arrival: DateTime(2026, 6, 11, 12, 30),
            fromStopId: 'OULU:201',
            toStopId: 'OULU:205',
          ),
        ]),
        itineraryJson([
          busLegJson(
            tripId: 'OULU:222',
            departure: dep.add(const Duration(minutes: 15)),
            arrival: DateTime(2026, 6, 11, 12, 50),
            fromStopId: 'OULU:201',
            toStopId: 'OULU:206',
          ),
        ]),
      ]);
      final timetable = {
        'stop0': {
          'gtfsId': 'OULU:201',
          'stoptimesWithoutPatterns': [
            for (final entry in {
              'OULU:111': 0,
              'OULU:222': 900,
              'OULU:333': 1800,
              'OULU:444': 2700,
            }.entries)
              stoptimeJson(
                tripId: entry.key,
                scheduledDeparture: noonSecs + entry.value,
                serviceDay: serviceDay,
              ),
          ],
        },
      };

      final options = await makeService(
        planClient(plan: plan, timetable: timetable),
      ).fetchRoutes(65.0, 25.4, 65.1, 25.5, dep, 120, 1.4);

      // Kaksi OTP:n ehdotusta + kaksi kopiota nopeammasta pohjasta.
      expect(options.map((o) => o.busLegs.single.tripId), [
        'OULU:111',
        'OULU:222',
        'OULU:333',
        'OULU:444',
      ]);
      expect(options[2].busLegs.single.toStopId, 'OULU:205');
    });

    test('OTP:n saapumisviive säilyy, vaikka se poikkeaa lähtöviiveestä',
        () async {
      final leg1Arr = DateTime(2026, 6, 11, 12, 20);
      final leg2Dep = DateTime(2026, 6, 11, 12, 24);
      final plan = planJson([
        itineraryJson([
          // Lähtee 6 min myöhässä, kirii saapumiseen mennessä 2 minuuttiin.
          busLegJson(
            tripId: 'OULU:111',
            departure: dep,
            arrival: leg1Arr,
            fromStopId: 'OULU:201',
            toStopId: 'OULU:203',
            departureDelaySec: 360,
            arrivalDelaySec: 120,
            realTime: true,
          ),
          busLegJson(
            tripId: 'OULU:222',
            departure: leg2Dep,
            arrival: DateTime(2026, 6, 11, 12, 40),
            fromStopId: 'OULU:203',
            toStopId: 'OULU:205',
          ),
        ]),
      ]);

      final options = await makeService(
        planClient(plan: plan, timetable: {}),
      ).fetchRoutes(65.0, 25.4, 65.1, 25.5, dep, 120, 1.4);

      final legs = options.single.busLegs;
      expect(
        displayedLegArrival(legs[0], null),
        DateTime(2026, 6, 11, 12, 22),
      );
      // 12:22 → 12:24: vaihto onnistuu (ei "voi jäädä").
      expect(transferLatenessMinutes(legs[0], legs[1], null), -2);
    });

    test('järjestää vaihtoehdot viiveen huomioivan lähtöajan mukaan',
        () async {
      const walk = Duration(minutes: 3);
      // A: bussi 12:00, 10 min myöhässä. B: bussi 12:04 ajallaan.
      final plan = planJson([
        itineraryJson([
          walkLegJson(
            start: dep.add(const Duration(minutes: 10)).subtract(walk),
            duration: walk,
          ),
          busLegJson(
            tripId: 'OULU:111',
            departure: dep,
            arrival: DateTime(2026, 6, 11, 12, 30),
            fromStopId: 'OULU:201',
            toStopId: 'OULU:205',
            departureDelaySec: 600,
            arrivalDelaySec: 600,
            realTime: true,
          ),
        ]),
        itineraryJson([
          walkLegJson(
            start: dep.add(const Duration(minutes: 4)).subtract(walk),
            duration: walk,
          ),
          busLegJson(
            tripId: 'OULU:999',
            departure: dep.add(const Duration(minutes: 4)),
            arrival: DateTime(2026, 6, 11, 12, 34),
            fromStopId: 'OULU:301',
            toStopId: 'OULU:205',
            patternCode: 'OULU:30:0:01',
            realTime: true,
          ),
        ]),
      ]);

      final options = await makeService(
        planClient(plan: plan, timetable: {}),
      ).fetchRoutes(65.0, 25.4, 65.1, 25.5, dep, 120, 1.4);

      expect(options.map((o) => o.busLegs.single.tripId), [
        'OULU:999',
        'OULU:111',
      ]);
      // Myöhässä olevan bussin lähtöaika siirtyy viiveen verran.
      expect(
        displayedLeaveTime(options[1], null),
        dep.add(const Duration(minutes: 7)),
      );
      expect(options[1].leaveHomeTime, dep.subtract(walk));
    });

    test('eri pysäkkijärjestyksen vuoroa (variantti) ei kloonata', () async {
      final arr = DateTime(2026, 6, 11, 12, 30);
      final plan = planJson([
        itineraryJson([
          busLegJson(
            tripId: 'OULU:111',
            departure: dep,
            arrival: arr,
            fromStopId: 'OULU:201',
            toStopId: 'OULU:205',
          ),
        ]),
      ]);
      final timetable = {
        'stop0': {
          'gtfsId': 'OULU:201',
          'stoptimesWithoutPatterns': [
            stoptimeJson(
              tripId: 'OULU:111',
              scheduledDeparture: noonSecs,
              serviceDay: serviceDay,
            ),
            // Sama linjatunnus, mutta eri reitti (esim. koulukierros).
            stoptimeJson(
              tripId: 'OULU:444',
              scheduledDeparture: noonSecs + 600,
              serviceDay: serviceDay,
              patternCode: 'OULU:20:0:02',
            ),
            // Sama reitti 20 min myöhemmin.
            stoptimeJson(
              tripId: 'OULU:555',
              scheduledDeparture: noonSecs + 1200,
              serviceDay: serviceDay,
            ),
          ],
        },
      };

      final options = await makeService(
        planClient(plan: plan, timetable: timetable),
      ).fetchRoutes(65.0, 25.4, 65.1, 25.5, dep, 120, 1.4);

      expect(options.map((o) => o.busLegs.single.tripId), [
        'OULU:111',
        'OULU:555',
      ]);
    });

    test('OTP:n oma ehdotus säilyy, vaikka toinen ehdotus kattaa lähdön',
        () async {
      final dep2 = dep.add(const Duration(minutes: 15));
      final plan = planJson([
        itineraryJson([
          busLegJson(
            tripId: 'OULU:111',
            departure: dep,
            arrival: DateTime(2026, 6, 11, 12, 20),
            fromStopId: 'OULU:201',
            toStopId: 'OULU:203',
          ),
          busLegJson(
            tripId: 'OULU:222',
            departure: DateTime(2026, 6, 11, 12, 30),
            arrival: DateTime(2026, 6, 11, 12, 50),
            fromStopId: 'OULU:203',
            toStopId: 'OULU:205',
          ),
        ]),
        // OTP:n tarkka ehdotus myöhemmälle lähdölle: eri vaihtobussi.
        itineraryJson([
          busLegJson(
            tripId: 'OULU:333',
            departure: dep2,
            arrival: DateTime(2026, 6, 11, 12, 35),
            fromStopId: 'OULU:201',
            toStopId: 'OULU:203',
          ),
          busLegJson(
            tripId: 'OULU:666',
            departure: DateTime(2026, 6, 11, 13, 10),
            arrival: DateTime(2026, 6, 11, 13, 30),
            fromStopId: 'OULU:203',
            toStopId: 'OULU:205',
          ),
        ]),
      ]);
      final timetable = {
        'stop0': {
          'gtfsId': 'OULU:201',
          'stoptimesWithoutPatterns': [
            stoptimeJson(
              tripId: 'OULU:111',
              scheduledDeparture: noonSecs,
              serviceDay: serviceDay,
            ),
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
      // Myöhempi lähtö on OTP:n oma ehdotus, ei ensimmäisen kopio.
      expect(options[1].busLegs[0].tripId, 'OULU:333');
      expect(options[1].busLegs[1].tripId, 'OULU:666');
      expect(
        options[1].busLegs[1].departureTime,
        DateTime(2026, 6, 11, 13, 10),
      );
    });

    test('tallentaa kävelyjen kestot', () async {
      final walkStart = dep.subtract(const Duration(minutes: 4));
      final arr = DateTime(2026, 6, 11, 12, 30);
      final plan = planJson([
        itineraryJson([
          walkLegJson(start: walkStart, duration: const Duration(minutes: 4)),
          busLegJson(
            tripId: 'OULU:111',
            departure: dep,
            arrival: arr,
            fromStopId: 'OULU:201',
            toStopId: 'OULU:205',
          ),
          walkLegJson(start: arr, duration: const Duration(minutes: 2)),
        ]),
      ]);

      final options = await makeService(
        planClient(plan: plan, timetable: {}),
      ).fetchRoutes(65.0, 25.4, 65.1, 25.5, dep, 120, 1.4);

      expect(options.single.walkDurations, const [
        Duration(minutes: 4),
        Duration(minutes: 2),
      ]);
      expect(options.single.leaveHomeTime, walkStart);
    });

    test('näyttää vain vaiheen aikana voimassa olevat tiedotteet kerran',
        () async {
      int secs(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
      final arr = DateTime(2026, 6, 11, 12, 30);
      final plan = planJson([
        itineraryJson([
          busLegJson(
            tripId: 'OULU:111',
            departure: dep,
            arrival: arr,
            fromStopId: 'OULU:201',
            toStopId: 'OULU:205',
            alerts: [
              {
                'alertHeaderText': 'Poikkeusreitti',
                'effectiveStartDate': secs(DateTime(2026, 6, 11, 6)),
                'effectiveEndDate': secs(DateTime(2026, 6, 11, 18)),
              },
              // Sama tiedote toista kautta (esim. pysäkki) – vain kerran.
              {
                'alertHeaderText': 'Poikkeusreitti',
                'effectiveStartDate': null,
                'effectiveEndDate': null,
              },
              // Päättynyt eilen.
              {
                'alertHeaderText': 'Vanha tiedote',
                'effectiveStartDate': secs(DateTime(2026, 6, 9)),
                'effectiveEndDate': secs(DateTime(2026, 6, 10)),
              },
            ],
          ),
        ]),
      ]);

      final options = await makeService(
        planClient(plan: plan, timetable: {}),
      ).fetchRoutes(65.0, 25.4, 65.1, 25.5, dep, 120, 1.4);

      final leg = options.single.busLegs.single;
      // Kaikki tiedotteet talteen (kopioitu lähtö voi osua eri aikaan)…
      expect(leg.alerts, hasLength(3));
      // …mutta näytetään vain vaiheen aikana voimassa olevat, kerran.
      expect(activeLegAlerts(leg, null).map((a) => a.text), [
        'Poikkeusreitti',
      ]);
    });

    test('GraphQL-virhe ilman plan-osaa heittää poikkeuksen', () {
      final client = MockClient((request) async {
        return http.Response(
          json.encode({
            'errors': [
              {'message': 'Validation error'},
            ],
            'data': null,
          }),
          200,
          headers: _jsonHeaders,
        );
      });

      expect(
        () => makeService(
          client,
        ).fetchRoutes(65.0, 25.4, 65.1, 25.5, dep, 120, 1.4),
        throwsException,
      );
    });
  });

  group('fetchTripRealtime', () {
    BusLeg leg(String tripId, {String serviceDate = ''}) => BusLeg(
      busNumber: '20',
      tripId: tripId,
      serviceDate: serviceDate,
      fromStop: 'Tori',
      fromStopId: 'OULU:201',
      toStop: 'Yliopisto',
      departureTime: DateTime(2026, 6, 11, 12, 0),
      arrivalTime: DateTime(2026, 6, 11, 12, 30),
      realtimeDeparture: DateTime(2026, 6, 11, 12, 0),
      realtimeState: 'SCHEDULED',
      isRealtime: false,
    );

    test('kysyy vuoron ajat liikennöintipäivälle (stoptimesForDate)',
        () async {
      late String body;
      final client = MockClient((request) async {
        body = request.body;
        return http.Response(json.encode({'data': {}}), 200,
            headers: _jsonHeaders);
      });

      await makeService(client).fetchTripRealtime([
        leg('OULU:111', serviceDate: '20260611'),
        leg('OULU:111', serviceDate: '20260611'), // sama vuoro vain kerran
        leg('OULU:222'),
      ]);

      // Trip.stoptimes palauttaisi pelkän aikataulun ilman reaaliaikaa.
      expect(body, isNot(contains('stoptimes {')));
      expect(body, contains('stoptimesForDate(serviceDate: \\"20260611\\")'));
      expect('trip(id:'.allMatches(body), hasLength(2));
    });

    test('kysyy enintään 30 vuoroa annetussa tärkeysjärjestyksessä', () async {
      late String body;
      final client = MockClient((request) async {
        body = request.body;
        return http.Response(json.encode({'data': {}}), 200,
            headers: _jsonHeaders);
      });

      await makeService(client).fetchTripRealtime([
        for (int i = 0; i < 35; i++) leg('OULU:$i'),
      ]);

      expect('trip(id:'.allMatches(body), hasLength(30));
      expect(body, contains('OULU:0'));
      expect(body, contains('OULU:29'));
      expect(body, isNot(contains('OULU:30')));
    });

    test('parsii vain reaaliaikaiset pysäkit vuoroittain', () async {
      final serviceDay = DateTime(2026, 6, 11).millisecondsSinceEpoch ~/ 1000;
      final client = MockClient((request) async {
        return http.Response(
          json.encode({
            'data': {
              'trip0': {
                'gtfsId': 'OULU:111',
                'stoptimesForDate': [
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
      ).fetchTripRealtime([leg('OULU:111'), leg('OULU:999')]);

      expect(result, isNotNull);
      expect(result!.keys, ['OULU:111']);
      final visits = result['OULU:111']!.visitsByStopId;
      expect(visits.keys, ['OULU:201']);
      final stop = visits['OULU:201']!.single;
      expect(stop.departure, DateTime(2026, 6, 11, 12, 5));
      expect(stop.arrival, DateTime(2026, 6, 11, 12, 4));
      expect(stop.realtimeState, 'UPDATED');
    });

    test('rengasreitin pysäkin molemmat käynnit säilyvät', () async {
      final serviceDay = DateTime(2026, 6, 11).millisecondsSinceEpoch ~/ 1000;
      Map<String, dynamic> row(int scheduled, int realtime) => {
        'stop': {'gtfsId': 'OULU:201'},
        'scheduledArrival': scheduled,
        'scheduledDeparture': scheduled,
        'realtimeArrival': realtime,
        'realtimeDeparture': realtime,
        'realtime': true,
        'realtimeState': 'UPDATED',
        'serviceDay': serviceDay,
      };
      final client = MockClient((request) async {
        return http.Response(
          json.encode({
            'data': {
              'trip0': {
                'gtfsId': 'OULU:111',
                'stoptimesForDate': [
                  row(8 * 3600, 8 * 3600 + 60), // lähtö 08:00, +1 min
                  row(8 * 3600 + 2400, 8 * 3600 + 2400), // paluu 08:40
                ],
              },
            },
          }),
          200,
          headers: _jsonHeaders,
        );
      });

      final result = await makeService(
        client,
      ).fetchTripRealtime([leg('OULU:111')]);

      final boardingLeg = BusLeg(
        busNumber: '20',
        tripId: 'OULU:111',
        fromStop: 'Tori',
        fromStopId: 'OULU:201',
        toStop: 'Yliopisto',
        departureTime: DateTime(2026, 6, 11, 8, 0),
        arrivalTime: DateTime(2026, 6, 11, 8, 20),
        realtimeDeparture: DateTime(2026, 6, 11, 8, 0),
        realtimeState: 'SCHEDULED',
        isRealtime: false,
      );
      expect(result!['OULU:111']!.visitsByStopId['OULU:201'], hasLength(2));
      // Lähtö kello 8 ei saa näyttää paluukäynnin aikaa (+40 min).
      expect(
        realtimeLegDeparture(boardingLeg, result),
        DateTime(2026, 6, 11, 8, 1),
      );
    });

    test('palauttaa null virheestä, jotta vanha data säilyy', () async {
      final client = MockClient(
        (request) async => http.Response('error', 500),
      );

      expect(
        await makeService(client).fetchTripRealtime([leg('OULU:111')]),
        isNull,
      );
    });

    test('palauttaa null, kun GraphQL-vastauksessa ei ole dataa', () async {
      final client = MockClient((request) async {
        return http.Response(
          json.encode({
            'errors': [
              {'message': 'Query cost too high'},
            ],
          }),
          200,
          headers: _jsonHeaders,
        );
      });

      expect(
        await makeService(client).fetchTripRealtime([leg('OULU:111')]),
        isNull,
      );
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

  group('fetchTripRoute', () {
    test('hakee vuoron pysäkit liikennöintipäivältä reaaliaikoineen',
        () async {
      late String body;
      final client = MockClient((request) async {
        body = request.body;
        return http.Response(
          json.encode({
            'data': {
              'trip': {
                'stoptimesForDate': [
                  {
                    'stop': {
                      'name': 'Tori',
                      'gtfsId': 'OULU:201',
                      'lat': 65.01,
                      'lon': 25.47,
                    },
                    'scheduledDeparture': 43200,
                    'realtimeDeparture': 43500,
                    'realtimeState': 'UPDATED',
                    'realtime': true,
                    'serviceDay': 1780000000,
                  },
                ],
              },
            },
          }),
          200,
          headers: _jsonHeaders,
        );
      });

      final stops = await makeService(
        client,
      ).fetchTripRoute('OULU:111', serviceDate: '20260611');

      expect(body, contains('stoptimesForDate(serviceDate: \\"20260611\\")'));
      expect(stops, hasLength(1));
      expect(stops!.single['realtime'], isTrue);
    });

    test('virheellinen päivä jätetään pois kyselystä', () async {
      late String body;
      final client = MockClient((request) async {
        body = request.body;
        return http.Response(json.encode({'data': {'trip': null}}), 200,
            headers: _jsonHeaders);
      });

      await makeService(
        client,
      ).fetchTripRoute('OULU:111', serviceDate: '2026-06-11"){x}');

      expect(body, isNot(contains('serviceDate')));
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
