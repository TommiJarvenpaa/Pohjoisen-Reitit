import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../models/app_models.dart';
import '../theme/app_colors.dart';
import 'shimmer_widgets.dart';

class StopBoardSheet extends StatefulWidget {
  final String stopId;
  final String stopName;
  final String digitransitKey;
  final String Function(DateTime) formatTime;
  final ScrollController scrollController;
  final VoidCallback? onSetAsStart;
  final VoidCallback? onSetAsDestination;

  const StopBoardSheet({
    super.key,
    required this.stopId,
    required this.stopName,
    required this.digitransitKey,
    required this.formatTime,
    required this.scrollController,
    this.onSetAsStart,
    this.onSetAsDestination,
  });

  @override
  State<StopBoardSheet> createState() => _StopBoardSheetState();
}

class _StopBoardSheetState extends State<StopBoardSheet> {
  bool _isLoading = true;
  List<StopTimeData> _departures = [];

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  Future<void> _fetchData() async {
    final startTimeSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final String query =
        """
    {
      stop(id: "${widget.stopId}") {
        stoptimesWithoutPatterns(startTime: $startTimeSec, timeRange: 7200, numberOfDepartures: 20) {
          scheduledDeparture realtimeDeparture realtimeState realtime serviceDay headsign
          trip { route { shortName } }
        }
      }
    }
    """;

    try {
      final response = await http.post(
        Uri.parse('https://api.digitransit.fi/routing/v2/waltti/gtfs/v1'),
        headers: {
          'Content-Type': 'application/json',
          'digitransit-subscription-key': widget.digitransitKey,
        },
        body: json.encode({'query': query}),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final stoptimes =
            data['data']?['stop']?['stoptimesWithoutPatterns']
                as List<dynamic>?;

        if (stoptimes != null && mounted) {
          List<StopTimeData> departures = [];
          for (var st in stoptimes) {
            String? rName = st['trip']?['route']?['shortName'];
            int? schedDep = st['scheduledDeparture'];
            int? realDep = st['realtimeDeparture'];
            int? serviceDay = st['serviceDay'];
            String rtState = st['realtimeState'] ?? 'SCHEDULED';
            bool isRt = st['realtime'] ?? false;
            String headsign = st['headsign'] ?? '';

            if (rName != null && schedDep != null && serviceDay != null) {
              departures.add(
                StopTimeData(
                  scheduledEpochSec: serviceDay + schedDep,
                  realtimeEpochSec: serviceDay + (realDep ?? schedDep),
                  realtimeState: rtState,
                  isRealtime: isRt,
                  busNumber: rName,
                  headsign: headsign,
                ),
              );
            }
          }
          setState(() => _departures = departures);
        }
      }
    } catch (e) {
      debugPrint('Stop board fetch error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
            child: Row(
              children: [
                const Icon(Icons.transfer_within_a_station, color: kStop),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.stopName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: kStop,
                    ),
                  ),
                ),
                if (widget.onSetAsStart != null)
                  IconButton(
                    icon: const Icon(Icons.trip_origin, color: kWalk),
                    tooltip: 'Aseta lähtöpisteeksi',
                    onPressed: widget.onSetAsStart,
                  ),
                if (widget.onSetAsDestination != null)
                  IconButton(
                    icon: const Icon(Icons.location_on, color: kPrimary),
                    tooltip: 'Aseta määränpääksi',
                    onPressed: widget.onSetAsDestination,
                  ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: _isLoading
                ? const StopBoardShimmer()
                : _departures.isEmpty
                ? const Center(child: Text('Ei tulevia lähtöjä lähiaikoina.'))
                : ListView.builder(
                    controller: widget.scrollController,
                    itemCount: _departures.length,
                    itemBuilder: (context, index) {
                      final dep = _departures[index];
                      final depTime = DateTime.fromMillisecondsSinceEpoch(
                        dep.realtimeEpochSec * 1000,
                      );
                      final bool isDelayed =
                          dep.isRealtime &&
                          dep.realtimeEpochSec > dep.scheduledEpochSec;

                      return ListTile(
                        leading: BusNumberBadge(dep.busNumber ?? ''),
                        title: Text(dep.headsign ?? 'Päätepysäkki puuttuu'),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              widget.formatTime(depTime),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: isDelayed
                                    ? kDelayed
                                    : (dep.isRealtime
                                          ? kOnTime
                                          : Colors.black87),
                              ),
                            ),
                            if (dep.isRealtime)
                              Icon(
                                Icons.rss_feed,
                                size: 12,
                                color: isDelayed ? kDelayed : kOnTime,
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// Laita tämä samaan tiedostoon tai erilliseen. BusNumberBadge on kopioitu route_cardista tänne riippuvuuksien helpottamiseksi.
class BusNumberBadge extends StatelessWidget {
  final String busNumber;
  const BusNumberBadge(this.busNumber, {super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: kBus,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: kBus.withValues(alpha: 0.35),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        busNumber,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 14,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
