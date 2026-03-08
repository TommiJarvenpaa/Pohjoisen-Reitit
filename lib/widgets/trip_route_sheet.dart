import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/app_models.dart';
import '../providers/app_providers.dart';
import '../theme/app_colors.dart';

class TripRouteSheet extends ConsumerStatefulWidget {
  final BusLeg leg;
  final String Function(DateTime) formatTime;

  const TripRouteSheet({
    super.key,
    required this.leg,
    required this.formatTime,
  });

  @override
  ConsumerState<TripRouteSheet> createState() => _TripRouteSheetState();
}

class _TripRouteSheetState extends ConsumerState<TripRouteSheet> {
  bool _isLoading = true;
  List<Map<String, dynamic>>? _tripStops;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchTripData();
  }

  Future<void> _fetchTripData() async {
    try {
      final api = ref.read(transitServiceProvider);
      final stops = await api.fetchTripRoute(
        widget.leg.tripId,
        widget.leg.routeGtfsId,
      );

      if (mounted) {
        setState(() {
          _tripStops = stops;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Reitin hakeminen epäonnistui.';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Kahva
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Otsikko
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: kBus,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    widget.leg.busNumber,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Koko reitti',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: kPrimaryDark,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.grey),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Sisältö
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: kPrimary),
                  )
                : _error != null
                ? Center(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  )
                : _tripStops == null || _tripStops!.isEmpty
                ? const Center(child: Text('Reittitietoja ei saatavilla.'))
                : _buildStopsList(),
          ),
        ],
      ),
    );
  }

  Widget _buildStopsList() {
    // Selvitetään, missä kohtaa reittiä käyttäjä on mukana
    int userStartIndex = _tripStops!.indexWhere(
      (st) => st['stop']['gtfsId'] == widget.leg.fromStopId,
    );
    int userEndIndex = _tripStops!.indexWhere(
      (st) => st['stop']['gtfsId'] == widget.leg.toStopId,
    );

    if (userStartIndex == -1) {
      userStartIndex = 0;
    }
    if (userEndIndex == -1) {
      userEndIndex = _tripStops!.length - 1;
    }

    // --- AIKAVYÖHYKKEEN KORJAUS ---
    // Lasketaan oikea "tämän päivän keskiyö" käyttäjän lähtöajan perusteella!
    final int userStartSchedSecs =
        _tripStops![userStartIndex]['scheduledDeparture'] as int? ?? 0;
    final DateTime baseMidnight = widget.leg.departureTime.subtract(
      Duration(seconds: userStartSchedSecs),
    );
    // ------------------------------

    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottomPadding),
      itemCount: _tripStops!.length,
      itemBuilder: (context, index) {
        final stopData = _tripStops![index];
        final stopInfo = stopData['stop'];
        final stopName = stopInfo['name'] ?? 'Tuntematon pysäkki';

        final int schedSecs = stopData['scheduledDeparture'] as int? ?? 0;
        final int realSecs = stopData['realtimeDeparture'] as int? ?? schedSecs;
        final bool isRealtime = stopData['realtime'] ?? false;

        // PÄIVITETTY: Käytetään laskettua keskiyötä 1970-vuoden sijaan!
        DateTime scheduledTime = baseMidnight.add(Duration(seconds: schedSecs));
        DateTime displayTime = baseMidnight.add(Duration(seconds: realSecs));

        // Määritetään pysäkin visuaalinen tila
        bool isPast = index < userStartIndex;
        bool isUserJourney = index >= userStartIndex && index <= userEndIndex;

        bool isUserStart = index == userStartIndex;
        bool isUserEnd = index == userEndIndex;

        Color dotColor;
        Color textColor;

        if (isPast) {
          dotColor = Colors.grey[300]!;
          textColor = Colors.grey;
        } else if (isUserJourney) {
          dotColor = kBus;
          textColor = const Color(0xFF222222);
        } else {
          dotColor = Colors.orange[300]!;
          textColor = Colors.black87;
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Aika
            SizedBox(
              width: 50,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    widget.formatTime(displayTime),
                    style: TextStyle(
                      fontWeight: isUserStart || isUserEnd
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isRealtime && !isPast
                          ? (displayTime.isAfter(scheduledTime)
                                ? kDelayed
                                : kOnTime)
                          : textColor,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),

            // Pysäkkiviiva ja pallo
            Column(
              children: [
                // Pallo
                Container(
                  width: isUserStart || isUserEnd ? 14 : 10,
                  height: isUserStart || isUserEnd ? 14 : 10,
                  margin: EdgeInsets.only(
                    top: isUserStart || isUserEnd ? 2 : 4,
                  ),
                  decoration: BoxDecoration(
                    color: isUserStart || isUserEnd ? Colors.white : dotColor,
                    shape: BoxShape.circle,
                    border: isUserStart || isUserEnd
                        ? Border.all(color: dotColor, width: 3)
                        : null,
                  ),
                ),
                // Viiva seuraavalle (jos ei ole viimeinen)
                if (index < _tripStops!.length - 1)
                  Container(
                    width: 3,
                    height: 24,
                    margin: const EdgeInsets.only(top: 4, bottom: 4),
                    decoration: BoxDecoration(
                      color: isPast
                          ? Colors.grey[200]
                          : (isUserJourney && index < userEndIndex
                                ? kBus.withValues(alpha: 0.5)
                                : Colors.orange.withValues(alpha: 0.3)),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 16),

            // Pysäkin nimi
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stopName,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isUserStart || isUserEnd
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: textColor,
                        decoration: isPast ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    if (isUserStart)
                      const Text(
                        'Nouset kyytiin tästä',
                        style: TextStyle(fontSize: 11, color: kBus),
                      ),
                    if (isUserEnd)
                      const Text(
                        'Jäät pois tässä',
                        style: TextStyle(fontSize: 11, color: Colors.orange),
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
