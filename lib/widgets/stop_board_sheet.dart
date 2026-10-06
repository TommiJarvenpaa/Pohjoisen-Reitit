import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/app_models.dart';
import '../providers/app_providers.dart';
import '../services/realtime_utils.dart';
import '../theme/app_colors.dart';
import 'shimmer_widgets.dart';
import 'route_card.dart'; // Tuodaan alkuperäinen, klikattava BusNumberBadge!

class StopBoardSheet extends ConsumerStatefulWidget {
  final String stopId;
  final String stopName;
  final String Function(DateTime) formatTime;
  final ScrollController scrollController;
  final VoidCallback? onSetAsStart;
  final VoidCallback? onSetAsDestination;

  const StopBoardSheet({
    super.key,
    required this.stopId,
    required this.stopName,
    required this.formatTime,
    required this.scrollController,
    this.onSetAsStart,
    this.onSetAsDestination,
  });

  @override
  ConsumerState<StopBoardSheet> createState() => _StopBoardSheetState();
}

class _StopBoardSheetState extends ConsumerState<StopBoardSheet> {
  bool _isLoading = true;
  String? _error;
  List<StopTimeData> _departures = [];

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  Future<void> _fetchData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final departures = await ref
          .read(transitServiceProvider)
          .fetchStopDepartures(widget.stopId);
      if (!mounted) return;
      setState(() {
        _departures = departures;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Stop board fetch error: $e');
      if (!mounted) return;
      setState(() {
        _error = 'Aikataulun hakeminen epäonnistui.';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Haetaan puhelimen alareunan SafeArea (navigointipalkin korkeus)
    final bottomPadding = MediaQuery.of(context).padding.bottom;

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
          Expanded(child: _buildBody(bottomPadding)),
        ],
      ),
    );
  }

  Widget _buildBody(double bottomPadding) {
    if (_isLoading) {
      return const StopBoardShimmer();
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: Colors.grey[700])),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _fetchData,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Yritä uudelleen'),
            ),
          ],
        ),
      );
    }
    if (_departures.isEmpty) {
      return const Center(child: Text('Ei tulevia lähtöjä lähiaikoina.'));
    }
    return ListView.builder(
      controller: widget.scrollController,
      // Padding alareunaan, jotta alin elementti ei jää navigointipalkin alle
      padding: EdgeInsets.only(bottom: bottomPadding),
      itemCount: _departures.length,
      itemBuilder: (context, index) {
        final dep = _departures[index];
        final scheduledTime = DateTime.fromMillisecondsSinceEpoch(
          dep.scheduledEpochSec * 1000,
        );
        final depTime = DateTime.fromMillisecondsSinceEpoch(
          dep.realtimeEpochSec * 1000,
        );
        final bool isCanceled = dep.isCanceled;
        // Myöhässä vain, jos näytetty kellonaika poikkeaa aikataulusta.
        final bool isDelayed =
            !isCanceled &&
            dep.isRealtime &&
            clockMinutesBetween(scheduledTime, depTime) > 0;

        // Luodaan "vale-BussiMatka", jotta voimme käyttää reittikortin
        // älykästä ja klikattavaa BusNumberBadgea. departureTime on
        // aikataulun mukainen, kuten reittikortin vaiheissa.
        final dummyLeg = BusLeg(
          busNumber: dep.busNumber ?? '',
          routeGtfsId: dep.routeGtfsId,
          tripId: dep.tripId,
          fromStop: widget.stopName,
          fromStopId: widget.stopId,
          toStop: dep.headsign ?? '',
          toStopId: '', // Tyhjä = Koko reitti -näkymä näyttää päätepysäkille asti!
          legStopIds: [widget.stopId],
          departureTime: scheduledTime,
          arrivalTime: scheduledTime,
          realtimeDeparture: depTime,
          realtimeState: dep.realtimeState,
          isRealtime: dep.isRealtime,
          stayOnBus: false,
          intermediateStops: const [],
          alerts: const [],
          serviceDate: dep.serviceDate,
        );

        return ListTile(
          leading: BusNumberBadge(leg: dummyLeg, formatTime: widget.formatTime),
          title: Text(
            dep.headsign ?? '',
            style: isCanceled ? const TextStyle(color: Colors.grey) : null,
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                widget.formatTime(isCanceled ? scheduledTime : depTime),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  decoration: isCanceled ? TextDecoration.lineThrough : null,
                  color: isCanceled
                      ? Colors.grey
                      : isDelayed
                      ? kDelayed
                      : (dep.isRealtime ? kOnTime : Colors.black87),
                ),
              ),
              if (isCanceled)
                const Text(
                  'Peruttu',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: kDelayed,
                  ),
                )
              else if (dep.isRealtime)
                Icon(
                  Icons.rss_feed,
                  size: 12,
                  color: isDelayed ? kDelayed : kOnTime,
                ),
            ],
          ),
        );
      },
    );
  }
}
