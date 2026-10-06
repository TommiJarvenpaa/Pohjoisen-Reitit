import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pohjoisen_reitit/models/app_models.dart';
import 'package:pohjoisen_reitit/providers/app_providers.dart';
import 'package:pohjoisen_reitit/services/transit_service.dart';
import 'package:pohjoisen_reitit/widgets/route_card.dart';
import 'package:pohjoisen_reitit/widgets/trip_route_sheet.dart';

String _fmt(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

void main() {
  testWidgets(
    'RouteCard ei kaadu, vaikka välimuistireitiltä puuttuvat kävelymatkat',
    (tester) async {
      final leg = BusLeg(
        busNumber: '20',
        fromStop: 'Tori',
        fromStopId: 'OULU:201',
        toStop: 'Yliopisto',
        departureTime: DateTime(2026, 6, 11, 12, 0),
        arrivalTime: DateTime(2026, 6, 11, 12, 30),
        realtimeDeparture: DateTime(2026, 6, 11, 12, 0),
        realtimeState: 'SCHEDULED',
        isRealtime: false,
      );
      // Vanhasta välimuistista ladattu reitti: walkDistances puuttuu (= []).
      final option = RouteOption(
        leaveHomeTime: DateTime(2026, 6, 11, 11, 55),
        arrivalTime: DateTime(2026, 6, 11, 12, 35),
        busLegs: [leg],
        segments: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RouteCard(
                option: option,
                isSelected: false,
                isFavorite: false,
                isOfflineData: true,
                formatTime: (t) =>
                    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                onTap: () {},
                onToggleFavorite: () {},
                onShare: () {},
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(RouteCard), findsOneWidget);
      expect(find.text('11:55'), findsOneWidget);
    },
  );

  testWidgets(
    'BusLegSection näyttää live-feedin viiveen, vaikka vaihe ei ole '
    'hakuhetken tilannekuvassa reaaliaikainen',
    (tester) async {
      final dep = DateTime(2026, 6, 11, 12, 0);
      // Vaihtobussi: tilannekuva ei tunne viivettä (isRealtime: false).
      final leg = BusLeg(
        busNumber: '20',
        tripId: 'OULU:111',
        fromStop: 'Tori',
        fromStopId: 'OULU:201',
        toStop: 'Yliopisto',
        toStopId: 'OULU:205',
        legStopIds: const ['OULU:201', 'OULU:205'],
        departureTime: dep,
        arrivalTime: dep.add(const Duration(minutes: 30)),
        realtimeDeparture: dep,
        realtimeState: 'SCHEDULED',
        isRealtime: false,
      );
      // Live-seuranta tietää lähdön olevan 5 min myöhässä.
      final tripRealtime = {
        'OULU:111': TripRealtime(
          byStopId: {
            'OULU:201': StopRealtime(
              departure: dep.add(const Duration(minutes: 5)),
            ),
          },
        ),
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BusLegSection(
              leg: leg,
              formatTime: _fmt,
              tripRealtime: tripRealtime,
              now: DateTime(2026, 6, 11, 11, 0),
            ),
          ),
        ),
      );

      // Viive näkyy: reaaliaikainen aika ja viivemerkki.
      expect(find.text('12:05'), findsOneWidget);
      expect(find.text('5 min myöhässä'), findsOneWidget);
    },
  );

  BusLeg makeLeg({
    DateTime? departure,
    DateTime? realtimeDeparture,
    bool isRealtime = false,
  }) {
    final dep = departure ?? DateTime(2026, 10, 6, 7, 46);
    return BusLeg(
      busNumber: '20K',
      tripId: 'OULU:111',
      fromStop: 'Kauppakuja E',
      fromStopId: 'OULU:201',
      toStop: 'Linja-autoasema',
      toStopId: 'OULU:205',
      legStopIds: const ['OULU:201', 'OULU:205'],
      departureTime: dep,
      arrivalTime: dep.add(const Duration(minutes: 50)),
      realtimeDeparture: realtimeDeparture ?? dep,
      realtimeState: 'UPDATED',
      isRealtime: isRealtime,
    );
  }

  Future<void> pumpSection(
    WidgetTester tester,
    BusLeg leg, [
    Map<String, TripRealtime>? tripRealtime,
  ]) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BusLegSection(
          leg: leg,
          formatTime: _fmt,
          tripRealtime: tripRealtime,
          now: DateTime(2026, 10, 6, 7, 0),
        ),
      ),
    ),
  );

  testWidgets('viivemerkki täsmää näytettyihin kellonaikoihin', (
    tester,
  ) async {
    // Kuvakaappauksen tapaus: aikataulu sekunteineen, ero 7 min 30 s.
    await pumpSection(
      tester,
      makeLeg(
        departure: DateTime(2026, 10, 6, 7, 46, 40),
        realtimeDeparture: DateTime(2026, 10, 6, 7, 54, 10),
        isRealtime: true,
      ),
    );

    expect(find.text('07:54'), findsOneWidget);
    expect(find.text('8 min myöhässä'), findsOneWidget);
  });

  testWidgets('ohitettu nousupysäkki näkyy, ei "ajallaan"-aikana', (
    tester,
  ) async {
    final leg = makeLeg();
    await pumpSection(tester, leg, {
      'OULU:111': TripRealtime(
        byStopId: {
          'OULU:201': StopRealtime(
            departure: leg.departureTime,
            realtimeState: 'CANCELED',
          ),
        },
      ),
    });

    expect(find.text('Ei pysähdy'), findsOneWidget);
    expect(find.text('peruttu'), findsNothing);
  });

  Future<void> pumpCard(
    WidgetTester tester,
    RouteOption option, [
    Map<String, TripRealtime>? tripRealtime,
  ]) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: RouteCard(
            option: option,
            isSelected: true,
            isFavorite: false,
            isOfflineData: false,
            formatTime: _fmt,
            onTap: () {},
            onToggleFavorite: () {},
            onShare: () {},
            tripRealtime: tripRealtime,
            now: DateTime(2026, 10, 6, 7, 0),
          ),
        ),
      ),
    ),
  );

  testWidgets('lähtöaika seuraa bussin viivettä, aikataulu rinnalla', (
    tester,
  ) async {
    final leg = makeLeg(
      realtimeDeparture: DateTime(2026, 10, 6, 7, 54),
      isRealtime: true,
    );
    await pumpCard(
      tester,
      RouteOption(
        leaveHomeTime: DateTime(2026, 10, 6, 7, 43),
        arrivalTime: leg.arrivalTime.add(const Duration(minutes: 5)),
        busLegs: [leg],
        segments: [],
        walkDistances: const [268, 300],
      ),
    );
    await tester.tap(find.text('Näytä tiedot'));
    await tester.pumpAndSettle();

    expect(
      find.text('Lähde klo 07:51  aikataulu 07:43', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('peruttu vaihe näkyy kortin varoituksena ilman vaihtomerkintää', (
    tester,
  ) async {
    final first = makeLeg();
    final second = BusLeg(
      busNumber: '5',
      tripId: 'OULU:222',
      fromStop: 'Linja-autoasema',
      fromStopId: 'OULU:205',
      toStop: 'Yliopisto',
      toStopId: 'OULU:300',
      departureTime: first.arrivalTime.add(const Duration(minutes: 1)),
      arrivalTime: first.arrivalTime.add(const Duration(minutes: 20)),
      realtimeDeparture: first.arrivalTime.add(const Duration(minutes: 1)),
      realtimeState: 'SCHEDULED',
      isRealtime: false,
    );
    await pumpCard(
      tester,
      RouteOption(
        leaveHomeTime: DateTime(2026, 10, 6, 7, 43),
        arrivalTime: second.arrivalTime,
        busLegs: [first, second],
        segments: [],
      ),
      {
        'OULU:111': TripRealtime(
          byStopId: {
            'OULU:201': StopRealtime(realtimeState: 'CANCELED'),
            'OULU:205': StopRealtime(realtimeState: 'CANCELED'),
          },
        ),
      },
    );
    await tester.tap(find.text('Näytä tiedot'));
    await tester.pumpAndSettle();

    expect(find.text('Reitin bussivuoro on peruttu'), findsOneWidget);
    // Merkki sekä suljetun kortin linjarivillä että vaiheen lähtörivillä.
    expect(find.text('peruttu'), findsNWidgets(2));
    // 1 min vaihto olisi muuten "tiukka" – perutulle vaiheelle ei näytetä.
    expect(find.textContaining('tiukka'), findsNothing);
  });

  testWidgets('koko reitin näkymä näyttää perutun pysäkin, ei vihreää aikaa', (
    tester,
  ) async {
    final serviceDay = DateTime(2026, 10, 6).millisecondsSinceEpoch ~/ 1000;
    Map<String, dynamic> row(String id, String name, int secs, String state) =>
        {
          'stop': {'name': name, 'gtfsId': id, 'lat': 65.0, 'lon': 25.4},
          'scheduledDeparture': secs,
          'realtimeDeparture': secs,
          'realtimeState': state,
          'realtime': true,
          'serviceDay': serviceDay,
        };
    final client = MockClient((request) async {
      return http.Response(
        json.encode({
          'data': {
            'trip': {
              'stoptimesForDate': [
                row('OULU:201', 'Kauppakuja E', 7 * 3600 + 46 * 60, 'UPDATED'),
                row('OULU:202', 'Hukantie E', 7 * 3600 + 47 * 60, 'CANCELED'),
                row('OULU:205', 'Linja-autoasema', 8 * 3600, 'UPDATED'),
              ],
            },
          },
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          transitServiceProvider.overrideWithValue(
            TransitService(
              digitransitKey: 'k',
              walttiClientId: 'i',
              walttiClientSecret: 's',
              client: client,
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TripRouteSheet(leg: makeLeg(), formatTime: _fmt),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Hukantie E'), findsOneWidget);
    expect(find.text('Ei pysähdy'), findsOneWidget);
  });

  testWidgets('peruttu vuoro näkyy peruttu-merkintänä', (tester) async {
    final leg = makeLeg();
    await pumpSection(tester, leg, {
      'OULU:111': TripRealtime(
        byStopId: {
          'OULU:201': StopRealtime(
            departure: leg.departureTime,
            realtimeState: 'CANCELED',
          ),
          'OULU:205': StopRealtime(
            arrival: leg.arrivalTime,
            realtimeState: 'CANCELED',
          ),
        },
      ),
    });

    expect(find.text('peruttu'), findsOneWidget);
  });
}
