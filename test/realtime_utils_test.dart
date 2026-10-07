import 'package:flutter_test/flutter_test.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:pohjoisen_reitit/models/app_models.dart';
import 'package:pohjoisen_reitit/services/realtime_utils.dart';

BusLeg makeLeg({
  String tripId = 'OULU:111',
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

Map<String, TripRealtime> realtimeMap({
  String tripId = 'OULU:111',
  required String stopId,
  DateTime? departure,
  DateTime? arrival,
  String realtimeState = 'UPDATED',
}) => {
  tripId: TripRealtime(
    byStopId: {
      stopId: StopRealtime(
        departure: departure,
        arrival: arrival,
        realtimeState: realtimeState,
      ),
    },
  ),
};

void main() {
  group('getRealtimeStopTime / getRealtimeArrivalTime', () {
    final depTime = DateTime(2026, 6, 11, 12, 16);
    final arrTime = DateTime(2026, 6, 11, 12, 14);

    test('palauttaa lähtöajan kun pysäkillä on molemmat ajat', () {
      final data = realtimeMap(
        stopId: 'OULU:202',
        departure: depTime,
        arrival: arrTime,
      );
      final leg = makeLeg();

      expect(getRealtimeStopTime(data, leg, 'OULU:202'), depTime);
      expect(getRealtimeArrivalTime(data, leg, 'OULU:202'), arrTime);
    });

    test('käyttää toista aikaa kun ensisijainen puuttuu', () {
      final data = realtimeMap(stopId: 'OULU:202', departure: depTime);
      final leg = makeLeg();

      // Saapumisaikaa ei ole, joten palautuu lähtöaika.
      expect(getRealtimeArrivalTime(data, leg, 'OULU:202'), depTime);
    });

    test('vaatii vuoron gtfsId:n eksaktin täsmäyksen', () {
      // Eri vuoro samalla "ytimellä" ei enää kelpaa – id:t tulevat
      // samasta reititys-API:sta, joten niiden kuuluu olla identtiset.
      final data = realtimeMap(
        tripId: 'OULU:111_20260611',
        stopId: 'OULU:202',
        departure: depTime,
      );

      expect(getRealtimeStopTime(data, makeLeg(), 'OULU:202'), isNull);
    });

    test('palauttaa null kun pysäkki ei täsmää', () {
      final data = realtimeMap(stopId: 'OULU:777', departure: depTime);

      expect(getRealtimeStopTime(data, makeLeg(), 'OULU:202'), isNull);
    });

    test('palauttaa null ilman dataa tai trip-id:tä', () {
      expect(getRealtimeStopTime(null, makeLeg(), 'OULU:202'), isNull);

      final data = realtimeMap(stopId: 'OULU:202', departure: depTime);
      expect(
        getRealtimeStopTime(data, makeLeg(tripId: ''), 'OULU:202'),
        isNull,
      );
    });

    test('hylkää eri liikennöintipäivän ajan (sama vuoro, eri päivä)', () {
      // Jos vaiheen päivä puuttuu (vanha välimuisti), OTP palauttaa
      // kuluvan päivän ajat – toisen päivän samalle vuorolle ne eivät kelpaa.
      final data = realtimeMap(
        stopId: 'OULU:202',
        departure: DateTime(2026, 6, 10, 12, 16),
      );

      expect(getRealtimeStopTime(data, makeLeg(), 'OULU:202'), isNull);
    });

    test('perutun pysäkin aikaa ei näytetä "ajallaan"-tietona', () {
      // OTP antaa perutulle pysäkille aikataulun ajan.
      final data = realtimeMap(
        stopId: 'OULU:201',
        departure: DateTime(2026, 6, 11, 12, 0),
        realtimeState: 'CANCELED',
      );
      final leg = makeLeg();

      expect(getRealtimeStopTime(data, leg, 'OULU:201'), isNull);
      expect(getRealtimeArrivalTime(data, leg, 'OULU:201'), isNull);
      expect(isStopCanceled(data, leg, 'OULU:201'), isTrue);
      expect(isStopCanceled(data, leg, 'OULU:205'), isFalse);
    });
  });

  group('taaksepäin kopioitu viive (ohitetut pysäkit)', () {
    final now = DateTime(2026, 6, 11, 12, 30);
    List<DateTime> minutesFromNoon(List<int> minutes) => [
      for (final m in minutes) DateTime(2026, 6, 11, 12, m),
    ];

    test('tunnistaa vuoron alun yhtenäisen saman viiveen jakson', () {
      // Kuten oikeassa datassa: ohitetuilla pysäkeillä täsmälleen sama
      // +236 s, sitten aidot arviot. Jakson kaksi viimeistä jätetään
      // aidoiksi (kopioinnin lähde ja mahdollinen samanarvoinen ennuste).
      final b = detectBackfill(
        [236, 236, 236, 236, 236, 213, 200],
        minutesFromNoon([0, 3, 6, 9, 12, 15, 18]),
        now,
      );
      expect(b.copies, 3);
      expect(b.passed, 3);
    });

    test('koko vuoron sama viive tai lyhyt jakso ei ole kopiointia', () {
      final times = minutesFromNoon([0, 3, 6, 9]);
      expect(detectBackfill([60, 60, 60, 60], times, now).copies, 0);
      expect(detectBackfill([60, 75, 75, 90], times, now).copies, 0);
      // Kahden pysäkin jakso voi olla lähde + aito ennuste.
      expect(detectBackfill([60, 60, 75, 90], times, now).copies, 0);
    });

    test('pysäkki, jonka aikataulu ei ole vielä mennyt, ei ole ohitettu', () {
      final soon = detectBackfill(
        [120, 120, 120, 90],
        minutesFromNoon([25, 28, 31, 34]),
        now,
      );
      expect(soon.copies, 1);
      expect(soon.passed, 1);

      final later = detectBackfill(
        [120, 120, 120, 90],
        minutesFromNoon([40, 43, 46, 49]),
        now,
      );
      expect(later.copies, 1);
      expect(later.passed, 0);
    });

    test('päätepysäkillä myöhässä olevaa vuoroa ei merkitä lähteneeksi', () {
      // Vuoro lähtisi 12:25, mutta bussi on vielä edellisellä kierroksella
      // (+10 min). Syöte raportoi vasta myöhemmältä pysäkiltä, joten OTP
      // kopioi viiveen alkuun – kopio, mutta bussi ei ole lähtenyt.
      final b = detectBackfill(
        [600, 600, 600, 540],
        minutesFromNoon([25, 28, 31, 34]),
        now,
      );
      expect(b.copies, 1);
      expect(b.passed, 0);
    });

    // Käyttäjän esimerkki: bussi lähti pysäkiltä ajallaan 12:00, jäi matkalla
    // 4 min jälkeen, ja OTP kopioi +4 min ohitetulle pysäkille (12:04).
    Map<String, TripRealtime> backfilledBoarding() => {
      'OULU:111': TripRealtime(
        byStopId: {
          'OULU:201': StopRealtime(
            departure: DateTime(2026, 6, 11, 12, 4),
            scheduled: DateTime(2026, 6, 11, 12, 0),
            isPassed: true,
            isBackfilled: true,
          ),
        },
      ),
    };

    test('kopioitua aikaa ei näytetä lähtöaikana', () {
      final data = backfilledBoarding();

      expect(getRealtimeStopTime(data, makeLeg(), 'OULU:201'), isNull);
      expect(hasPassedStop(data, makeLeg(), 'OULU:201'), isTrue);
      expect(legDepartureSource(makeLeg(), data), RealtimeSource.schedule);
    });

    test('bussi on lähtenyt, vaikka kopioitu aika on vielä tulossa', () {
      final option = RouteOption(
        leaveHomeTime: DateTime(2026, 6, 11, 11, 55),
        arrivalTime: DateTime(2026, 6, 11, 12, 40),
        busLegs: [makeLeg()],
        segments: [],
      );
      // Kello 12:02: kopioitu lähtö 12:04 näyttäisi tulevalta.
      final s = tripStatus(
        option,
        backfilledBoarding(),
        DateTime(2026, 6, 11, 12, 2),
      );

      expect(s.phase, TripPhase.departed);
      expect(s.busDeparture, DateTime(2026, 6, 11, 12, 0));
      expect(
        legProgress(
          makeLeg(),
          backfilledBoarding(),
          DateTime(2026, 6, 11, 12, 2),
        ).hasDeparted,
        isTrue,
      );
    });

    test('muistaa viimeisen aidon ennusteen ennen ohitusta', () {
      final before = {
        'OULU:111': TripRealtime(
          byStopId: {
            'OULU:201': StopRealtime(
              departure: DateTime(2026, 6, 11, 12, 0, 20),
              scheduled: DateTime(2026, 6, 11, 12, 0),
            ),
          },
        ),
      };

      final merged = mergeTripRealtime(before, backfilledBoarding());
      final leg = makeLeg();

      expect(
        getRealtimeStopTime(merged, leg, 'OULU:201'),
        DateTime(2026, 6, 11, 12, 0, 20),
      );
      expect(hasPassedStop(merged, leg, 'OULU:201'), isTrue);
      // Seuraavakin kopioitu päivitys ei muuta jäädytettyä aikaa.
      final again = mergeTripRealtime(merged, backfilledBoarding());
      expect(
        getRealtimeStopTime(again, leg, 'OULU:201'),
        DateTime(2026, 6, 11, 12, 0, 20),
      );
    });

    test('ohitettu pysyy ohitettuna, vaikka tunnistus katoaa', () {
      // Vuoron lopussa koko jäljellä oleva osa voi olla samaa viivettä,
      // jolloin uusi haku ei enää tunnista kopiointia.
      final undetected = {
        'OULU:111': TripRealtime(
          byStopId: {
            'OULU:201': StopRealtime(
              departure: DateTime(2026, 6, 11, 12, 4),
              scheduled: DateTime(2026, 6, 11, 12, 0),
            ),
          },
        ),
      };

      final merged = mergeTripRealtime(backfilledBoarding(), undetected);

      expect(hasPassedStop(merged, makeLeg(), 'OULU:201'), isTrue);
      expect(getRealtimeStopTime(merged, makeLeg(), 'OULU:201'), isNull);
    });

    test('etuajassa lähteneen bussin aito lähtöaika ei korvaudu kopiolla', () {
      // Bussi lähti 11:58 (aikataulu 12:00). Kello 11:59 syöte ei enää
      // raportoi pysäkkiä ja OTP kopioi sille viiveen 0 (12:00); aikataulu ei
      // ole vielä mennyt, joten pysäkkiä ei merkitä ohitetuksi.
      final before = {
        'OULU:111': TripRealtime(
          byStopId: {
            'OULU:201': StopRealtime(
              departure: DateTime(2026, 6, 11, 11, 58),
              scheduled: DateTime(2026, 6, 11, 12, 0),
            ),
          },
        ),
      };
      final copy = {
        'OULU:111': TripRealtime(
          byStopId: {
            'OULU:201': StopRealtime(
              departure: DateTime(2026, 6, 11, 12, 0),
              scheduled: DateTime(2026, 6, 11, 12, 0),
              isBackfilled: true,
            ),
          },
        ),
      };

      final merged = mergeTripRealtime(before, copy);

      expect(
        getRealtimeStopTime(merged, makeLeg(), 'OULU:201'),
        DateTime(2026, 6, 11, 11, 58),
      );
    });

    test('lähteneen bussin lähtöaika ei ole tulevaisuudessa', () {
      // Hakuhetken ennuste 12:04, mutta syöte kertoo bussin ohittaneen
      // pysäkin jo kello 12:02 – näytetään aikataulun aika.
      final leg = makeLeg(
        realtimeDeparture: DateTime(2026, 6, 11, 12, 4),
        isRealtime: true,
      );

      expect(
        departedTime(leg, backfilledBoarding(), DateTime(2026, 6, 11, 12, 2)),
        DateTime(2026, 6, 11, 12, 0),
      );
    });

    test('seuraavaksi lähdöksi ei tarjota jo ohittanutta bussia', () {
      RouteOption option(String tripId, DateTime dep) => RouteOption(
        leaveHomeTime: dep.subtract(const Duration(minutes: 5)),
        arrivalTime: dep.add(const Duration(minutes: 30)),
        busLegs: [makeLeg(tripId: tripId, departureTime: dep)],
        segments: [],
      );
      final options = [
        option('OULU:100', DateTime(2026, 6, 11, 11, 50)),
        option('OULU:111', DateTime(2026, 6, 11, 12, 0)),
        option('OULU:222', DateTime(2026, 6, 11, 12, 20)),
      ];

      // Kello 11:58: 12:00-bussi on jo ohittanut pysäkin (kopioitu aika).
      expect(
        nextSameLineDeparture(
          options,
          0,
          backfilledBoarding(),
          DateTime(2026, 6, 11, 11, 58),
        ),
        DateTime(2026, 6, 11, 12, 20),
      );
    });
  });

  group('clockMinutesBetween', () {
    test('laskee eron näytetyistä kellonajoista (kuvakaappauksen tapaus)', () {
      // 07:46:40 → 07:54:10 näkyy "07:46 → 07:54": +8, ei +7.
      expect(
        clockMinutesBetween(
          DateTime(2026, 10, 6, 7, 46, 40),
          DateTime(2026, 10, 6, 7, 54, 10),
        ),
        8,
      );
      // 07:43:30 → 08:41:10 näkyy "07:43 → 08:41": 58 min, ei 57.
      expect(
        clockMinutesBetween(
          DateTime(2026, 10, 6, 7, 43, 30),
          DateTime(2026, 10, 6, 8, 41, 10),
        ),
        58,
      );
    });

    test('saman minuutin sisällä ero on nolla, etuajassa negatiivinen', () {
      expect(
        clockMinutesBetween(
          DateTime(2026, 10, 6, 7, 46, 0),
          DateTime(2026, 10, 6, 7, 46, 50),
        ),
        0,
      );
      expect(
        clockMinutesBetween(
          DateTime(2026, 10, 6, 7, 46, 10),
          DateTime(2026, 10, 6, 7, 45, 50),
        ),
        -1,
      );
    });
  });

  group('realtimeLegDeparture / displayedLegArrival', () {
    test('live-seurannan aika ohittaa hakuhetken tilannekuvan', () {
      final leg = makeLeg(
        realtimeDeparture: DateTime(2026, 6, 11, 12, 8),
        isRealtime: true,
      );
      final data = realtimeMap(
        stopId: 'OULU:201',
        departure: DateTime(2026, 6, 11, 12, 3),
      );

      expect(realtimeLegDeparture(leg, data), DateTime(2026, 6, 11, 12, 3));
      // Saapuminen siirtyy live-viiveellä (3 min), ei tilannekuvan 8 min.
      expect(displayedLegArrival(leg, data), DateTime(2026, 6, 11, 12, 33));
    });

    test('ilman reaaliaikatietoa palautuu aikataulu', () {
      final leg = makeLeg();

      expect(realtimeLegDeparture(leg, null), isNull);
      expect(displayedLegArrival(leg, null), leg.arrivalTime);
    });
  });

  group('tripIdMatches (sijaintifeedin sumea vertailu)', () {
    test('täysin sama id täsmää', () {
      expect(tripIdMatches('OULU:111_20260611', 'OULU:111_20260611'), isTrue);
    });

    test('namespace- ja suffiksierot eivät estä täsmäystä', () {
      expect(tripIdMatches('waltti:111_20260611', 'OULU:111_20260612'), isTrue);
      expect(tripIdMatches('111', 'OULU:111_20260611'), isTrue);
    });

    test('osittainen numero-osuma ei täsmää', () {
      expect(tripIdMatches('100123456', '1001234567'), isFalse);
    });
  });

  group('getRealtimeCurrentStopIndex', () {
    test('löytää pysäkin vehicle.stopId:n perusteella', () {
      final feed = FeedMessage(
        entity: [
          FeedEntity(
            id: 'v1',
            vehicle: VehiclePosition(
              trip: TripDescriptor(tripId: 'waltti:111', routeId: 'OULU:20'),
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
              trip: TripDescriptor(tripId: 'waltti:111', routeId: 'OULU:20'),
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
              trip: TripDescriptor(tripId: 'waltti:111', routeId: 'OULU:99'),
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
        tripId: 'OULU:222',
        departureTime: DateTime(2026, 6, 11, 12, 33),
        realtimeDeparture: DateTime(2026, 6, 11, 12, 33),
      );

      expect(transferLatenessMinutes(prev, next, null), 2);
    });

    test('ajallaan oleva vaihto tuottaa negatiivisen arvon', () {
      final prev = makeLeg(); // saapuu 12:30
      final next = makeLeg(
        tripId: 'OULU:222',
        departureTime: DateTime(2026, 6, 11, 12, 40),
        realtimeDeparture: DateTime(2026, 6, 11, 12, 40),
      );

      expect(transferLatenessMinutes(prev, next, null), -10);
    });

    test('käyttää reaaliaikatietoja kun ne ovat saatavilla', () {
      final prev = makeLeg(); // aikataulussa perillä 12:30
      final next = makeLeg(
        tripId: 'OULU:222',
        fromStopId: 'OULU:205',
        departureTime: DateTime(2026, 6, 11, 12, 36),
        realtimeDeparture: DateTime(2026, 6, 11, 12, 36),
      );
      final data = {
        // Edellinen bussi perillä vasta 12:38 – vaihto 12:36 jää välistä.
        'OULU:111': TripRealtime(
          byStopId: {
            'OULU:205': StopRealtime(arrival: DateTime(2026, 6, 11, 12, 38)),
          },
        ),
      };

      expect(transferLatenessMinutes(prev, next, data), 2);
    });

    test('vaihtokävely syö vaihtoajan', () {
      final prev = makeLeg(); // saapuu 12:30
      final next = makeLeg(
        tripId: 'OULU:222',
        departureTime: DateTime(2026, 6, 11, 12, 34),
        realtimeDeparture: DateTime(2026, 6, 11, 12, 34),
      );

      // 4 min väliä, mutta pysäkkien välillä kävellään 5 min.
      expect(
        transferLatenessMinutes(
          prev,
          next,
          null,
          transferWalk: const Duration(minutes: 5),
        ),
        1,
      );
    });

    test('pienikin myöhästyminen tarkoittaa, että vaihto voi jäädä', () {
      final prev = makeLeg(); // saapuu 12:30:00
      final next = makeLeg(
        tripId: 'OULU:222',
        departureTime: DateTime(2026, 6, 11, 12, 29, 30),
        realtimeDeparture: DateTime(2026, 6, 11, 12, 29, 30),
      );

      // Aiemmin 30 s katkesi nollaksi ja näkyi vain "tiukka".
      expect(transferLatenessMinutes(prev, next, null), 1);
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

    test('reaaliaikainen saapumisaika ohittaa arvion', () {
      final leg = makeLeg(
        realtimeDeparture: DateTime(2026, 6, 11, 12, 5),
        isRealtime: true,
      );
      final data = realtimeMap(
        stopId: 'OULU:205',
        arrival: DateTime(2026, 6, 11, 12, 37),
      );

      // 12:37 + 10 min kävely = 12:47.
      expect(
        realArrivalTime(makeOption(leg), data),
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

  // 30 min matka, 2 välipysäkkiä (A = OULU:202, B = OULU:203).
  final twoStops = [
    IntermediateStop(name: 'A', lat: 0, lon: 0, gtfsId: 'OULU:202'),
    IntermediateStop(name: 'B', lat: 0, lon: 0, gtfsId: 'OULU:203'),
  ];
  const twoStopIds = ['OULU:201', 'OULU:202', 'OULU:203', 'OULU:205'];

  group('intermediateStopTime', () {
    test('arvioi ajan lineaarisesti ilman reaaliaikatietoja', () {
      // Kolmasosa matkasta per väli.
      final leg = makeLeg(intermediateStops: twoStops, legStopIds: twoStopIds);

      final a = intermediateStopTime(0, leg, null);
      expect(a.time, DateTime(2026, 6, 11, 12, 10));
      expect(a.isLive, isFalse);
      expect(
        intermediateStopTime(1, leg, null).time,
        DateTime(2026, 6, 11, 12, 20),
      );
    });

    test('lisää viiveen arvioon kun matka on myöhässä', () {
      final leg = makeLeg(
        realtimeDeparture: DateTime(2026, 6, 11, 12, 5),
        isRealtime: true,
        intermediateStops: twoStops,
        legStopIds: twoStopIds,
      );

      expect(
        intermediateStopTime(0, leg, null).time,
        DateTime(2026, 6, 11, 12, 15),
      );
    });

    test('arvio käyttää samaa live-viivettä kuin lähtörivi', () {
      // Tilannekuvassa ei viivettä, live-seuranta tietää 5 min viiveen
      // lähtöpysäkillä mutta ei välipysäkeillä.
      final leg = makeLeg(intermediateStops: twoStops, legStopIds: twoStopIds);
      final data = realtimeMap(
        stopId: 'OULU:201',
        departure: DateTime(2026, 6, 11, 12, 5),
      );

      final a = intermediateStopTime(0, leg, data);
      expect(a.time, DateTime(2026, 6, 11, 12, 15));
      expect(a.isLive, isFalse);
    });

    test('käyttää live-ennustetta kun se on saatavilla', () {
      final leg = makeLeg(intermediateStops: twoStops, legStopIds: twoStopIds);
      // Arvio pysäkille on 12:10, live-ennuste 12:13.
      final data = realtimeMap(
        stopId: 'OULU:202',
        departure: DateTime(2026, 6, 11, 12, 13),
      );

      final a = intermediateStopTime(0, leg, data);
      expect(a.time, DateTime(2026, 6, 11, 12, 13));
      expect(a.isLive, isTrue);
    });

    test('pysäkki ilman id:tä ei siirrä seuraavien pysäkkien id:itä', () {
      // legStopIds ohittaa pysäkit ilman id:tä; aiemmin B:n aika luettiin
      // väärältä pysäkiltä.
      final leg = makeLeg(
        intermediateStops: [
          IntermediateStop(name: 'Nimetön', lat: 0, lon: 0),
          IntermediateStop(name: 'B', lat: 0, lon: 0, gtfsId: 'OULU:203'),
        ],
        legStopIds: const ['OULU:201', 'OULU:203', 'OULU:205'],
      );
      final data = realtimeMap(
        stopId: 'OULU:203',
        departure: DateTime(2026, 6, 11, 12, 22),
      );

      expect(intermediateStopTime(0, leg, data).isLive, isFalse);
      expect(
        intermediateStopTime(1, leg, data).time,
        DateTime(2026, 6, 11, 12, 22),
      );
    });

    test('hylkää eri liikennöintipäivän ajan ja käyttää arviota', () {
      final leg = makeLeg(intermediateStops: twoStops, legStopIds: twoStopIds);
      final data = realtimeMap(
        stopId: 'OULU:202',
        departure: DateTime(2026, 6, 10, 12, 13),
      );

      expect(
        intermediateStopTime(0, leg, data).time,
        DateTime(2026, 6, 11, 12, 10),
      );
    });
  });

  group('intermediateStopTime pysäkin omalla aikataululla', () {
    // Epätasaiset välit: A heti alussa, B lähellä loppua (lineaarinen
    // arvio antaisi 12:10 ja 12:20).
    final scheduledStops = [
      IntermediateStop(
        name: 'A',
        lat: 0,
        lon: 0,
        gtfsId: 'OULU:202',
        scheduledTime: DateTime(2026, 6, 11, 12, 3, 20),
      ),
      IntermediateStop(
        name: 'B',
        lat: 0,
        lon: 0,
        gtfsId: 'OULU:203',
        scheduledTime: DateTime(2026, 6, 11, 12, 26),
        estimatedTime: DateTime(2026, 6, 11, 12, 29),
      ),
    ];

    test('ilman reaaliaikatietoa näytetään pysäkin oma aikataulu', () {
      final leg = makeLeg(
        intermediateStops: scheduledStops,
        legStopIds: twoStopIds,
      );

      final a = intermediateStopTime(0, leg, null);
      expect(a.time, DateTime(2026, 6, 11, 12, 3, 20));
      expect(a.kind, StopTimeKind.schedule);
    });

    test('hakuhetken pysäkkiennuste ohittaa lähtöviiveen siirron', () {
      final leg = makeLeg(
        realtimeDeparture: DateTime(2026, 6, 11, 12, 1),
        isRealtime: true,
        intermediateStops: scheduledStops,
        legStopIds: twoStopIds,
      );

      // A:lla ei ennustetta: aikataulu + lähtöviive 1 min.
      final a = intermediateStopTime(0, leg, null);
      expect(a.time, DateTime(2026, 6, 11, 12, 4, 20));
      expect(a.kind, StopTimeKind.estimate);
      // B:llä oma ennuste (viive kasvanut matkalla 3 minuuttiin).
      expect(
        intermediateStopTime(1, leg, null).time,
        DateTime(2026, 6, 11, 12, 29),
      );
    });

    test('live-lähtöviive siirtää pysäkin aikataulua', () {
      final leg = makeLeg(
        intermediateStops: scheduledStops,
        legStopIds: twoStopIds,
      );
      final data = realtimeMap(
        stopId: 'OULU:201',
        departure: DateTime(2026, 6, 11, 12, 5),
      );

      final a = intermediateStopTime(0, leg, data);
      expect(a.time, DateTime(2026, 6, 11, 12, 8, 20));
      expect(a.kind, StopTimeKind.estimate);
    });

    test('saapumisajan lähde: aikataulu, arvio tai live', () {
      final leg = makeLeg(
        intermediateStops: scheduledStops,
        legStopIds: twoStopIds,
      );

      expect(
        displayedLegArrivalEstimate(leg, null).kind,
        StopTimeKind.schedule,
      );
      expect(
        displayedLegArrivalEstimate(
          makeLeg(
            realtimeDeparture: DateTime(2026, 6, 11, 12, 2),
            isRealtime: true,
          ),
          null,
        ).kind,
        StopTimeKind.estimate,
      );
      final arrived = realtimeMap(
        stopId: 'OULU:205',
        arrival: DateTime(2026, 6, 11, 12, 31),
      );
      final live = displayedLegArrivalEstimate(leg, arrived);
      expect(live.kind, StopTimeKind.live);
      expect(live.time, DateTime(2026, 6, 11, 12, 31));
    });

    test('live-ennuste pysäkillä on tarkin', () {
      final leg = makeLeg(
        intermediateStops: scheduledStops,
        legStopIds: twoStopIds,
      );
      final data = realtimeMap(
        stopId: 'OULU:203',
        departure: DateTime(2026, 6, 11, 12, 27),
      );

      final b = intermediateStopTime(1, leg, data);
      expect(b.time, DateTime(2026, 6, 11, 12, 27));
      expect(b.kind, StopTimeKind.live);
    });
  });

  group('legProgress', () {
    // Lähtö 12:00, A ~12:10, B ~12:20, perillä 12:30.
    final leg = makeLeg(intermediateStops: twoStops, legStopIds: twoStopIds);

    test('ennen lähtöä mitään ei ole ohitettu', () {
      final p = legProgress(leg, null, DateTime(2026, 6, 11, 12, 0, 30));

      expect(p.hasDeparted, isFalse);
      expect(p.passedStops, 0);
    });

    test('matkalla ohitetut pysäkit lasketaan alusta', () {
      final p = legProgress(leg, null, DateTime(2026, 6, 11, 12, 15));

      expect(p.hasDeparted, isTrue);
      expect(p.passedStops, 1); // A ohitettu, B seuraavaksi
      expect(p.hasArrived, isFalse);
      expect(p.isLive, isFalse);
    });

    test('live-ennuste ratkaisee, onko pysäkki ohitettu', () {
      // Bussi myöhässä: A vasta 12:17 live-ennusteen mukaan.
      final data = {
        'OULU:111': TripRealtime(
          byStopId: {
            'OULU:201': StopRealtime(departure: DateTime(2026, 6, 11, 12, 7)),
            'OULU:202': StopRealtime(departure: DateTime(2026, 6, 11, 12, 17)),
          },
        ),
      };

      final p = legProgress(leg, data, DateTime(2026, 6, 11, 12, 15));

      expect(p.hasDeparted, isTrue);
      expect(p.passedStops, 0);
      expect(p.isLive, isTrue);
    });

    test('perillä kaikki pysäkit on ohitettu', () {
      final p = legProgress(leg, null, DateTime(2026, 6, 11, 12, 31));

      expect(p.passedStops, 2);
      expect(p.hasArrived, isTrue);
    });
  });

  group('tripStatus', () {
    // Lähde 11:55, bussi 12:00 (ks. realArrivalTime-ryhmä).
    RouteOption option({DateTime? realtimeDeparture}) => RouteOption(
      leaveHomeTime: DateTime(2026, 6, 11, 11, 55),
      arrivalTime: DateTime(2026, 6, 11, 12, 40),
      busLegs: [
        makeLeg(
          realtimeDeparture: realtimeDeparture,
          isRealtime: realtimeDeparture != null,
        ),
      ],
      segments: [],
    );

    test('yli 5 min ennen lähtöä', () {
      final s = tripStatus(option(), null, DateTime(2026, 6, 11, 11, 40));

      expect(s.phase, TripPhase.leaveLater);
      expect(s.minutesToLeave, 15);
    });

    test('lähtöön alle 5 min', () {
      final s = tripStatus(option(), null, DateTime(2026, 6, 11, 11, 52, 30));

      expect(s.phase, TripPhase.leaveSoon);
      expect(s.minutesToLeave, 3);
    });

    test('lähtöaika mennyt, bussi ei vielä lähtenyt', () {
      final s = tripStatus(option(), null, DateTime(2026, 6, 11, 11, 58));

      expect(s.phase, TripPhase.leaveNow);
      expect(s.busDeparture, DateTime(2026, 6, 11, 12, 0));
    });

    test('myöhässä oleva bussi siirtää lähtöaikaa ja lähtöä', () {
      // Bussi 8 min myöhässä: lähde 12:03, bussi 12:08.
      final late = option(realtimeDeparture: DateTime(2026, 6, 11, 12, 8));

      expect(
        tripStatus(late, null, DateTime(2026, 6, 11, 11, 58)).minutesToLeave,
        5,
      );
      expect(
        tripStatus(late, null, DateTime(2026, 6, 11, 12, 5)).phase,
        TripPhase.leaveNow,
      );
    });

    test('bussi lähtenyt', () {
      final s = tripStatus(option(), null, DateTime(2026, 6, 11, 12, 1));

      expect(s.phase, TripPhase.departed);
    });
  });

  group('legDepartureSource', () {
    test('live, hakuhetken ennuste tai aikataulu', () {
      final data = realtimeMap(
        stopId: 'OULU:201',
        departure: DateTime(2026, 6, 11, 12, 2),
      );

      expect(legDepartureSource(makeLeg(), data), RealtimeSource.live);
      expect(
        legDepartureSource(
          makeLeg(
            realtimeDeparture: DateTime(2026, 6, 11, 12, 2),
            isRealtime: true,
          ),
          null,
        ),
        RealtimeSource.snapshot,
      );
      expect(legDepartureSource(makeLeg(), null), RealtimeSource.schedule);
    });
  });

  group('nextSameLineDeparture', () {
    RouteOption option(String tripId, DateTime dep, {String bus = '20'}) =>
        RouteOption(
          leaveHomeTime: dep.subtract(const Duration(minutes: 5)),
          arrivalTime: dep.add(const Duration(minutes: 30)),
          busLegs: [
            makeLeg(tripId: tripId, departureTime: dep, busNumber: bus),
          ],
          segments: [],
        );

    test('löytää saman linjan seuraavan lähdön samalta pysäkiltä', () {
      final options = [
        option('OULU:1', DateTime(2026, 6, 11, 12, 0)),
        option('OULU:2', DateTime(2026, 6, 11, 12, 10), bus: '22'),
        option('OULU:3', DateTime(2026, 6, 11, 12, 30)),
        option('OULU:4', DateTime(2026, 6, 11, 12, 15)),
      ];

      expect(
        nextSameLineDeparture(options, 0, null, DateTime(2026, 6, 11, 11, 50)),
        DateTime(2026, 6, 11, 12, 15),
      );
    });

    test('ei tarjoa jo lähtenyttä vuoroa', () {
      final options = [
        option('OULU:1', DateTime(2026, 6, 11, 12, 0)),
        option('OULU:4', DateTime(2026, 6, 11, 12, 15)),
        option('OULU:5', DateTime(2026, 6, 11, 12, 45)),
      ];

      expect(
        nextSameLineDeparture(options, 0, null, DateTime(2026, 6, 11, 12, 20)),
        DateTime(2026, 6, 11, 12, 45),
      );
    });

    test('ohittaa perutut lähdöt ja palauttaa null, jos muita ei ole', () {
      final options = [
        option('OULU:1', DateTime(2026, 6, 11, 12, 0)),
        option('OULU:4', DateTime(2026, 6, 11, 12, 15)),
      ];
      final canceled = {
        'OULU:4': TripRealtime(
          byStopId: {
            'OULU:201': StopRealtime(realtimeState: 'CANCELED'),
            'OULU:205': StopRealtime(realtimeState: 'CANCELED'),
          },
        ),
      };

      expect(
        nextSameLineDeparture(
          options,
          0,
          canceled,
          DateTime(2026, 6, 11, 11, 50),
        ),
        isNull,
      );
    });
  });
}
