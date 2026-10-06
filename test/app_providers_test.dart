import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pohjoisen_reitit/models/app_models.dart';
import 'package:pohjoisen_reitit/providers/app_providers.dart';
import 'package:pohjoisen_reitit/services/transit_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

TransitService makeService(MockClient client) => TransitService(
  digitransitKey: 'test-key',
  walttiClientId: 'client-id',
  walttiClientSecret: 'client-secret',
  client: client,
);

MockClient failingClient() =>
    MockClient((request) async => http.Response('error', 500));

/// Vastaa plan-kyselyyn yhdellä bussireitillä (vuoro OULU:999), muihin
/// kyselyihin tyhjällä datalla.
MockClient planClient() => MockClient((request) async {
  if (!request.body.contains('plan(')) {
    return http.Response(json.encode({'data': {}}), 200,
        headers: _jsonHeaders);
  }
  return planResponse('OULU:999');
});

http.Response planResponse(String tripId) {
  final dep = DateTime(2026, 10, 6, 8, 0);
  final arr = DateTime(2026, 10, 6, 8, 40);
  return http.Response(
      json.encode({
        'data': {
          'plan': {
            'itineraries': [
              {
                'startTime': dep.millisecondsSinceEpoch,
                'endTime': arr.millisecondsSinceEpoch,
                'legs': [
                  {
                    'mode': 'BUS',
                    'startTime': dep.millisecondsSinceEpoch,
                    'endTime': arr.millisecondsSinceEpoch,
                    'distance': 15000,
                    'trip': {'gtfsId': tripId},
                    'route': {'shortName': '20K', 'gtfsId': 'OULU:20K'},
                    'from': {
                      'name': 'Kauppakuja E',
                      'lat': 65.2,
                      'lon': 25.35,
                      'stop': {'gtfsId': 'OULU:201'},
                    },
                    'to': {
                      'name': 'Linja-autoasema',
                      'lat': 65.01,
                      'lon': 25.48,
                      'stop': {'gtfsId': 'OULU:205'},
                    },
                  },
                ],
              },
            ],
          },
        },
      }),
      200,
      headers: _jsonHeaders,
    );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cachedDeparture = DateTime(2026, 10, 6, 7, 46);
  final cachedOption = RouteOption(
    leaveHomeTime: DateTime(2026, 10, 6, 7, 43),
    arrivalTime: DateTime(2026, 10, 6, 8, 33),
    segments: [],
    busLegs: [
      BusLeg(
        busNumber: '20K',
        tripId: 'OULU:111',
        fromStop: 'Kauppakuja E',
        fromStopId: 'OULU:201',
        toStop: 'Linja-autoasema',
        toStopId: 'OULU:205',
        departureTime: cachedDeparture,
        arrivalTime: DateTime(2026, 10, 6, 8, 30),
        // Hakuhetken viive, joka ei enää pidä paikkaansa.
        realtimeDeparture: cachedDeparture.add(const Duration(minutes: 8)),
        realtimeState: 'UPDATED',
        isRealtime: true,
      ),
    ],
  );

  Map<String, Object> cachePrefs() => {
    'last_route_options': json.encode([cachedOption.toJson()]),
    'last_dest_name': 'Linja-autoasema',
    'last_dest_lat': 65.01,
    'last_dest_lon': 25.48,
    'last_start_lat': 65.2,
    'last_start_lon': 25.35,
  };

  Future<void> search(RouteNotifier notifier, {required bool background}) =>
      notifier.searchRoute(
        65.2,
        25.35,
        65.01,
        25.48,
        DateTime(2026, 10, 6, 7, 55),
        120,
        5.0,
        destPlace: Place(name: 'Linja-autoasema', lat: 65.01, lon: 25.48),
        isBackgroundRefresh: background,
      );

  group('RouteNotifier: välimuistin reitti', () {
    test('ladataan offline-tilaan ilman hakuhetken viiveitä', () async {
      SharedPreferences.setMockInitialValues(cachePrefs());
      final notifier = RouteNotifier(makeService(failingClient()));

      final saved = await notifier.savedSearch();

      expect(notifier.state.isOffline, isTrue);
      final leg = notifier.state.options.single.busLegs.single;
      expect(leg.isRealtime, isFalse);
      expect(leg.realtimeDeparture, leg.departureTime);
      expect(leg.realtimeState, 'SCHEDULED');

      expect(saved, isNotNull);
      expect(saved!.destination.name, 'Linja-autoasema');
      expect(saved.start, isNull); // GPS-lähtö
      expect(saved.startLat, 65.2);
      expect(saved.startLon, 25.35);
    });

    test('epäonnistunut taustapäivitys jättää reitit offline-tilaan '
        'ilman virheilmoitusta', () async {
      SharedPreferences.setMockInitialValues(cachePrefs());
      final notifier = RouteNotifier(makeService(failingClient()));
      await notifier.savedSearch();

      await search(notifier, background: true);

      expect(notifier.state.isOffline, isTrue);
      expect(notifier.state.isRefreshing, isFalse);
      expect(notifier.state.errorMessage, isNull);
      expect(notifier.state.options.single.busLegs.single.tripId, 'OULU:111');
    });

    test('onnistunut taustapäivitys korvaa välimuistin reitit', () async {
      SharedPreferences.setMockInitialValues(cachePrefs());
      final notifier = RouteNotifier(makeService(planClient()));
      await notifier.savedSearch();

      await search(notifier, background: true);

      expect(notifier.state.isOffline, isFalse);
      expect(notifier.state.isRefreshing, isFalse);
      expect(notifier.state.options.single.busLegs.single.tripId, 'OULU:999');
      // Päivitetty reitti ei ole enää välimuistin reitti.
      expect(await notifier.savedSearch(), isNull);
    });

    test('epäonnistunut tavallinen haku näyttää virheen mutta ei '
        'poista offline-merkintää', () async {
      SharedPreferences.setMockInitialValues(cachePrefs());
      final notifier = RouteNotifier(makeService(failingClient()));
      await notifier.savedSearch();

      await search(notifier, background: false);

      expect(notifier.state.isOffline, isTrue);
      expect(notifier.state.errorMessage, isNotNull);
    });

    test('vanhentuneen haun tulos ei korvaa uudemman haun tulosta', () async {
      SharedPreferences.setMockInitialValues(cachePrefs());
      final List<Completer<void>> gates = [];
      int planCalls = 0;
      final client = MockClient((request) async {
        if (!request.body.contains('plan(')) {
          return http.Response(json.encode({'data': {}}), 200,
              headers: _jsonHeaders);
        }
        final int call = planCalls++;
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        return planResponse(call == 0 ? 'OULU:OLD' : 'OULU:NEW');
      });
      final notifier = RouteNotifier(makeService(client));
      await notifier.savedSearch();

      // Taustapäivitys alkaa ensin, käyttäjän haku sen jälkeen.
      final background = search(notifier, background: true);
      await pumpEventQueue();
      final foreground = search(notifier, background: false);
      await pumpEventQueue();
      expect(gates, hasLength(2));

      // Käyttäjän haku valmistuu ensin, taustapäivitys vasta sen jälkeen.
      gates[1].complete();
      await foreground;
      gates[0].complete();
      await background;

      expect(notifier.state.options.single.busLegs.single.tripId, 'OULU:NEW');
      expect(notifier.state.isOffline, isFalse);
      expect(notifier.state.isLoading, isFalse);
      expect(notifier.state.isRefreshing, isFalse);
    });

    test('välimuisti ei korvaa hakua, joka alkoi ennen sen latautumista',
        () async {
      SharedPreferences.setMockInitialValues(cachePrefs());
      final notifier = RouteNotifier(makeService(planClient()));

      // Haku alkaa heti, ennen kuin välimuisti on ehtinyt latautua.
      await search(notifier, background: false);
      await notifier.savedSearch();

      expect(notifier.state.isOffline, isFalse);
      expect(notifier.state.options.single.busLegs.single.tripId, 'OULU:999');
    });

    test('tallentaa lähtöpaikan ja valitun ajan päivitystä varten', () async {
      SharedPreferences.setMockInitialValues({});
      final start = Place(name: 'Kauppatori', lat: 65.013, lon: 25.465);
      final chosen = DateTime(2026, 10, 9, 10, 0);
      final first = RouteNotifier(makeService(planClient()));
      await first.searchRoute(
        start.lat,
        start.lon,
        65.01,
        25.48,
        chosen,
        120,
        5.0,
        destPlace: Place(name: 'Linja-autoasema', lat: 65.01, lon: 25.48),
        startPlace: start,
        chosenTime: chosen,
      );
      // Tallennus tapahtuu taustalla.
      await pumpEventQueue();

      // Uusi käynnistys lukee välimuistin.
      final saved = await RouteNotifier(
        makeService(failingClient()),
      ).savedSearch();

      expect(saved, isNotNull);
      expect(saved!.start?.name, 'Kauppatori');
      expect(saved.startLat, start.lat);
      expect(saved.departureTime, chosen);
    });
  });

  group('Asetukset', () {
    test('loaded valmistuu vasta, kun tallennetut arvot on luettu', () async {
      SharedPreferences.setMockInitialValues({
        'min_transfer_time': 600,
        'walk_speed_kmh': 3.0,
      });
      final transfer = MinTransferTimeNotifier();
      final walk = WalkSpeedNotifier();

      await Future.wait([transfer.loaded, walk.loaded]);

      expect(transfer.state, 600);
      expect(walk.state, 3.0);
    });
  });

  group('LiveBusState.hasFreshTripUpdates', () {
    test('tyhjä tulos ei sytytä Live-merkkiä', () {
      final state = LiveBusState(
        isActive: true,
        tripRealtime: {},
        tripUpdatesUpdatedAt: DateTime.now(),
      );

      expect(state.hasFreshTripUpdates, isFalse);
    });

    test('tuore reaaliaikatieto sytyttää Live-merkin', () {
      final state = LiveBusState(
        isActive: true,
        tripRealtime: {
          'OULU:111': TripRealtime(byStopId: {'OULU:201': StopRealtime()}),
        },
        tripUpdatesUpdatedAt: DateTime.now(),
      );

      expect(state.hasFreshTripUpdates, isTrue);
    });
  });
}
