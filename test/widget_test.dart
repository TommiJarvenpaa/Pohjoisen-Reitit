import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:pohjoisen_reitit/models/app_models.dart';
import 'package:pohjoisen_reitit/widgets/route_card.dart';

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
      // Live-feed tietää lähdön olevan 5 min myöhässä.
      final feed = FeedMessage(
        entity: [
          FeedEntity(
            id: '1',
            tripUpdate: TripUpdate(
              trip: TripDescriptor(tripId: 'OULU:111'),
              stopTimeUpdate: [
                TripUpdate_StopTimeUpdate(
                  stopId: '201',
                  departure: TripUpdate_StopTimeEvent(
                    time: Int64(
                      dep
                              .add(const Duration(minutes: 5))
                              .millisecondsSinceEpoch ~/
                          1000,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BusLegSection(
              leg: leg,
              formatTime: _fmt,
              tripUpdateFeed: feed,
            ),
          ),
        ),
      );

      // Viive näkyy: aikataulun aika, reaaliaikainen aika ja viivemerkki.
      expect(find.text('12:00'), findsOneWidget);
      expect(find.text('12:05'), findsOneWidget);
      expect(find.text('+5 min'), findsOneWidget);
    },
  );
}
