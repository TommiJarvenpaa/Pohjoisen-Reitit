import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Design tokens ────────────────────────────────────────────────────────────
const Color kPrimary = Color(0xFF003366);
const Color kPrimaryDark = Color(0xFF001A33);
const Color kAccent = Color(0xFFFFD54F);
const Color kBus = Color(0xFF0077C8);
const Color kBusLight = Color(0xFFE1F5FE);
const Color kWalk = Color(0xFF8E24AA);
const Color kOnTime = Color(0xFF4CAF50);
const Color kDelayed = Color(0xFFE53935);
const Color kSurface = Color(0xFFF5F6FA);
const Color kStop = Color(0xFF003366);
const Color kLiveBus = Color(0xFFFFD54F);
const Color kAlert = Color(0xFFF57C00);

// ─── Main ─────────────────────────────────────────────────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  runApp(const PohjoisenReitit());
}

// ─── App root ─────────────────────────────────────────────────────────────────
class PohjoisenReitit extends StatelessWidget {
  const PohjoisenReitit({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pohjoisen Reitit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: kPrimary,
          primary: kPrimary,
          secondary: kAccent,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('fi', 'FI'), Locale('en', 'US')],
      locale: const Locale('fi', 'FI'),
      home: const MapScreen(),
    );
  }
}

// ─── Shimmer ──────────────────────────────────────────────────────────────────
class _ShimmerBox extends StatefulWidget {
  final double width;
  final double height;
  final double radius;
  const _ShimmerBox({
    required this.width,
    required this.height,
    this.radius = 8,
  });

  @override
  State<_ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<_ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
    _anim = Tween<double>(
      begin: -2,
      end: 2,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            begin: Alignment(_anim.value - 1, 0),
            end: Alignment(_anim.value + 1, 0),
            colors: const [
              Color(0xFFEEEEEE),
              Color(0xFFE0E0E0),
              Color(0xFFEEEEEE),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShimmerCard extends StatelessWidget {
  const _ShimmerCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Row(
            children: [
              _ShimmerBox(width: 56, height: 28, radius: 14),
              SizedBox(width: 8),
              _ShimmerBox(width: 20, height: 20),
              SizedBox(width: 8),
              _ShimmerBox(width: 56, height: 28, radius: 14),
              Spacer(),
              _ShimmerBox(width: 60, height: 16, radius: 8),
            ],
          ),
          SizedBox(height: 14),
          _ShimmerBox(width: 200, height: 14),
          SizedBox(height: 8),
          _ShimmerBox(width: 160, height: 14),
          SizedBox(height: 8),
          _ShimmerBox(width: 220, height: 14),
        ],
      ),
    );
  }
}

// ─── Stop board shimmer ───────────────────────────────────────────────────────
class _StopBoardShimmer extends StatelessWidget {
  const _StopBoardShimmer();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: 6,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemBuilder: (_, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: const [
            _ShimmerBox(width: 48, height: 28, radius: 14),
            SizedBox(width: 12),
            Expanded(child: _ShimmerBox(width: double.infinity, height: 16)),
            SizedBox(width: 12),
            _ShimmerBox(width: 48, height: 22, radius: 6),
          ],
        ),
      ),
    );
  }
}

// ─── Map markers ──────────────────────────────────────────────────────────────
class _StartMarker extends StatelessWidget {
  const _StartMarker();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: kWalk,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: kWalk.withValues(alpha: 0.4),
            blurRadius: 8,
            spreadRadius: 2,
          ),
        ],
      ),
      child: const Icon(Icons.trip_origin, color: Colors.white, size: 18),
    );
  }
}

class _DestinationMarker extends StatelessWidget {
  const _DestinationMarker();
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: kPrimary,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: kPrimary.withValues(alpha: 0.4),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Icon(Icons.flag, color: Colors.white, size: 18),
        ),
        Container(width: 3, height: 10, color: kPrimary),
      ],
    );
  }
}

class _BoardingStopMarker extends StatelessWidget {
  final String name;
  const _BoardingStopMarker(this.name);
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Nousupysäkki: $name',
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: kOnTime,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: [
            BoxShadow(
              color: kOnTime.withValues(alpha: 0.45),
              blurRadius: 6,
              spreadRadius: 1,
            ),
          ],
        ),
        child: const Icon(Icons.arrow_upward, color: Colors.white, size: 11),
      ),
    );
  }
}

class _AlightingStopMarker extends StatelessWidget {
  final String name;
  const _AlightingStopMarker(this.name);
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Poistumispysäkki: $name',
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: kPrimary,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: [
            BoxShadow(
              color: kPrimary.withValues(alpha: 0.45),
              blurRadius: 6,
              spreadRadius: 1,
            ),
          ],
        ),
        child: const Icon(Icons.arrow_downward, color: Colors.white, size: 11),
      ),
    );
  }
}

class _StopDot extends StatelessWidget {
  final String name;
  const _StopDot(this.name);
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: name,
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: kStop, width: 3),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 3,
            ),
          ],
        ),
      ),
    );
  }
}

class _IntermediateStopDot extends StatelessWidget {
  final String name;
  const _IntermediateStopDot(this.name);
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: name,
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: kBus, width: 2),
          boxShadow: [
            BoxShadow(color: kBus.withValues(alpha: 0.25), blurRadius: 3),
          ],
        ),
      ),
    );
  }
}

class _LiveBusMarker extends StatelessWidget {
  final String busNumber;
  const _LiveBusMarker(this.busNumber);
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: kLiveBus,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: kLiveBus.withValues(alpha: 0.45),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            busNumber,
            style: const TextStyle(
              color: kPrimaryDark,
              fontWeight: FontWeight.bold,
              fontSize: 10,
            ),
          ),
        ),
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: kLiveBus,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: kLiveBus.withValues(alpha: 0.4),
                blurRadius: 8,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Icon(
            Icons.directions_bus,
            color: kPrimaryDark,
            size: 18,
          ),
        ),
      ],
    );
  }
}

class _BusNumberBadge extends StatelessWidget {
  final String busNumber;
  const _BusNumberBadge(this.busNumber);
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

// ─── Route card ───────────────────────────────────────────────────────────────
class _RouteCard extends StatelessWidget {
  final RouteOption option;
  final bool isSelected;
  final bool isFavorite;
  final bool isOfflineData;
  final String Function(DateTime) formatTime;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onShare;

  const _RouteCard({
    required this.option,
    required this.isSelected,
    required this.isFavorite,
    required this.isOfflineData,
    required this.formatTime,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final isWalkOnly = option.busLegs.isEmpty;
    final totalMinutes = option.arrivalTime
        .difference(option.leaveHomeTime)
        .inMinutes;

    // Collect all alerts across all bus legs
    final allAlerts = option.busLegs.expand((leg) => leg.alerts).toList();

    int currentWalkIndex = 0;
    List<Widget> timelineWidgets = [];

    timelineWidgets.add(
      _TimelineRow(
        icon: Icons.directions_walk,
        iconColor: kWalk,
        label: 'Lähde klo ${formatTime(option.leaveHomeTime)}',
        labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
    );

    for (int i = 0; i < option.busLegs.length; i++) {
      timelineWidgets.add(_TimelineDivider());

      if (currentWalkIndex < option.walkDistances.length &&
          option.walkDistances[currentWalkIndex] > 0) {
        timelineWidgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 28, bottom: 4),
            child: Text(
              'Kävele ${option.walkDistances[currentWalkIndex].round()} m',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
          ),
        );
        currentWalkIndex++;
      }

      timelineWidgets.add(
        _BusLegSection(leg: option.busLegs[i], formatTime: formatTime),
      );
    }

    if (currentWalkIndex < option.walkDistances.length &&
        option.walkDistances[currentWalkIndex] > 0) {
      timelineWidgets.add(_TimelineDivider());
      timelineWidgets.add(
        Padding(
          padding: const EdgeInsets.only(left: 28, bottom: 4),
          child: Text(
            'Kävele ${option.walkDistances[currentWalkIndex].round()} m',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFF0F4FF) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected ? kBus : Colors.transparent,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: isSelected
                  ? kBus.withValues(alpha: 0.15)
                  : Colors.black.withValues(alpha: 0.07),
              blurRadius: isSelected ? 16 : 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Offline badge
              if (isOfflineData)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.4),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi_off, size: 12, color: Colors.orange),
                      SizedBox(width: 4),
                      Text(
                        'Tallennettu reitti – ei reaaliaikainen',
                        style: TextStyle(fontSize: 10, color: Colors.orange),
                      ),
                    ],
                  ),
                ),
              Row(
                children: [
                  if (isWalkOnly)
                    _WalkBadge()
                  else
                    Wrap(
                      spacing: 6,
                      children: [
                        for (int i = 0; i < option.busLegs.length; i++) ...[
                          if (i > 0)
                            const Icon(
                              Icons.arrow_forward,
                              size: 14,
                              color: Colors.grey,
                            ),
                          _BusNumberBadge(option.busLegs[i].busNumber),
                        ],
                      ],
                    ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? kBus.withValues(alpha: 0.1)
                          : kSurface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$totalMinutes min',
                      style: TextStyle(
                        color: isSelected ? kBus : Colors.grey[600],
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Share button
                  GestureDetector(
                    onTap: onShare,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.share,
                        size: 18,
                        color: Colors.grey[400],
                      ),
                    ),
                  ),
                  // Favorite button
                  GestureDetector(
                    onTap: onToggleFavorite,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        isFavorite
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        size: 20,
                        color: isFavorite ? kAccent : Colors.grey[400],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ...timelineWidgets,
              const SizedBox(height: 8),
              const Divider(height: 1, color: Color(0xFFEEEEEE)),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.flag_rounded, color: kPrimary, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Perillä klo ${formatTime(option.arrivalTime)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: kPrimaryDark,
                    ),
                  ),
                ],
              ),
              // Alerts section
              if (allAlerts.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: kAlert.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kAlert.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.warning_amber_rounded,
                            color: kAlert,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Häiriötiedote${allAlerts.length > 1 ? 't' : ''}',
                            style: const TextStyle(
                              color: kAlert,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      for (final alert in allAlerts) ...[
                        const SizedBox(height: 4),
                        Text(
                          alert.text,
                          style: TextStyle(
                            color: Colors.grey[800],
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WalkBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: kWalk,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.directions_walk, color: Colors.white, size: 14),
          SizedBox(width: 4),
          Text(
            'Kävely',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final TextStyle? labelStyle;
  const _TimelineRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    this.labelStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 16),
        const SizedBox(width: 8),
        Text(label, style: labelStyle ?? const TextStyle(fontSize: 13)),
      ],
    );
  }
}

class _TimelineDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 7, top: 4, bottom: 4),
      child: Container(width: 2, height: 14, color: const Color(0xFFDDDDDD)),
    );
  }
}

class _BusLegSection extends StatefulWidget {
  final BusLeg leg;
  final String Function(DateTime) formatTime;
  const _BusLegSection({required this.leg, required this.formatTime});

  @override
  State<_BusLegSection> createState() => _BusLegSectionState();
}

class _BusLegSectionState extends State<_BusLegSection> {
  bool _showStops = false;

  @override
  Widget build(BuildContext context) {
    final BusLeg leg = widget.leg;
    final bool isCanceled = leg.realtimeState == 'CANCELED';
    final bool hasDelay =
        leg.isRealtime &&
        leg.realtimeDeparture.difference(leg.departureTime).inMinutes != 0;
    final int delayMin = leg.realtimeDeparture
        .difference(leg.departureTime)
        .inMinutes;
    final bool hasIntermediateStops = leg.intermediateStops.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: kBusLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.directions_bus, color: kBus, size: 15),
                    const SizedBox(width: 6),
                    Text(
                      'Linja ${leg.busNumber}',
                      style: const TextStyle(
                        color: kBus,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    if (hasIntermediateStops) ...[
                      const Spacer(),
                      GestureDetector(
                        onTap: () => setState(() => _showStops = !_showStops),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: kBus.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${leg.intermediateStops.length} pysäkkiä',
                                style: const TextStyle(
                                  color: kBus,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 2),
                              Icon(
                                _showStops
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 14,
                                color: kBus,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (isCanceled)
                      const Text(
                        'PERUTTU',
                        style: TextStyle(
                          color: kDelayed,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      )
                    else if (hasDelay) ...[
                      Text(
                        widget.formatTime(leg.departureTime),
                        style: const TextStyle(
                          decoration: TextDecoration.lineThrough,
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        widget.formatTime(leg.realtimeDeparture),
                        style: TextStyle(
                          color: delayMin > 0 ? kDelayed : kOnTime,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: (delayMin > 0 ? kDelayed : kOnTime).withValues(
                            alpha: 0.12,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${delayMin > 0 ? '+' : ''}$delayMin min',
                          style: TextStyle(
                            fontSize: 11,
                            color: delayMin > 0 ? kDelayed : kOnTime,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ] else
                      Text(
                        widget.formatTime(leg.departureTime),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '· ${leg.fromStop}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      widget.formatTime(leg.arrivalTime),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '· ${leg.toStop}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (hasIntermediateStops && _showStops)
            Container(
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  for (int i = 0; i < leg.intermediateStops.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: kBus.withValues(alpha: 0.45),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              leg.intermediateStops[i].name,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF333333),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Stop board sheet (StatefulWidget – opens immediately with shimmer) ────────
class _StopBoardSheet extends StatefulWidget {
  final String stopId;
  final String stopName;
  final String digitransitKey;
  final String Function(DateTime) formatTime;
  final ScrollController scrollController;
  final VoidCallback? onSetAsStart;
  final VoidCallback? onSetAsDestination;

  const _StopBoardSheet({
    required this.stopId,
    required this.stopName,
    required this.digitransitKey,
    required this.formatTime,
    required this.scrollController,
    this.onSetAsStart,
    this.onSetAsDestination,
  });

  @override
  State<_StopBoardSheet> createState() => _StopBoardSheetState();
}

class _StopBoardSheetState extends State<_StopBoardSheet> {
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
          // Handle
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
                // Set as start / destination buttons
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
                ? const _StopBoardShimmer()
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
                        leading: _BusNumberBadge(dep.busNumber ?? ''),
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

// ─── Favorite route model ─────────────────────────────────────────────────────
class FavoriteRoute {
  final String destinationName;
  final double destLat;
  final double destLon;
  final String? startName;
  final double? startLat;
  final double? startLon;
  final int savedAtMs;

  FavoriteRoute({
    required this.destinationName,
    required this.destLat,
    required this.destLon,
    this.startName,
    this.startLat,
    this.startLon,
    required this.savedAtMs,
  });

  Map<String, dynamic> toJson() => {
    'destinationName': destinationName,
    'destLat': destLat,
    'destLon': destLon,
    'startName': startName,
    'startLat': startLat,
    'startLon': startLon,
    'savedAtMs': savedAtMs,
  };

  factory FavoriteRoute.fromJson(Map<String, dynamic> json) => FavoriteRoute(
    destinationName: json['destinationName'],
    destLat: (json['destLat'] as num).toDouble(),
    destLon: (json['destLon'] as num).toDouble(),
    startName: json['startName'],
    startLat: (json['startLat'] as num?)?.toDouble(),
    startLon: (json['startLon'] as num?)?.toDouble(),
    savedAtMs: json['savedAtMs'] ?? 0,
  );

  String get displayLabel {
    final dest = destinationName;
    if (startName != null) return '$startName → $dest';
    return '📍 → $dest';
  }
}

// ─── Main screen ──────────────────────────────────────────────────────────────
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  LatLng _currentLocation = const LatLng(65.0121, 25.4651);
  bool _hasRealLocation = false;

  Map<String, dynamic>? _customStartFeature;
  Map<String, dynamic>? _destinationFeature;

  DateTime _departureTime = DateTime.now();
  bool _isSelectingStart = false;

  final MapController _mapController = MapController();
  bool _showSearchPanel = true;

  // Stop display
  bool _showBusStops = false;
  List<Map<String, dynamic>> _rawStops = [];
  List<Marker> _stopMarkers = [];
  bool _isFetchingStops = false;
  String _stopSearchQuery = '';
  final TextEditingController _stopSearchController = TextEditingController();

  // API keys
  final String _digitransitKey = dotenv.env['DIGITRANSIT_KEY'] ?? '';
  final String _walttiClientId = dotenv.env['WALTTI_CLIENT_ID'] ?? '';
  final String _walttiClientSecret = dotenv.env['WALTTI_CLIENT_SECRET'] ?? '';

  bool _isLoading = false;

  // Live buses
  FeedMessage? _latestFeedMessage;
  List<Marker> _busMarkers = [];
  Timer? _liveBusTimer;
  bool _isLiveTrackingActive = false;
  bool _isFetchingLiveBuses = false; // FIX: prevent concurrent fetches

  List<RouteOption> _routeOptions = [];
  int _selectedRouteIndex = 0;

  int _minTransferTime = 120;
  double _walkSpeedKmH = 5.0;
  double get _walkSpeedMS => _walkSpeedKmH / 3.6;

  // History
  final List<Map<String, dynamic>> _recentSearches = [];

  // Favorites
  List<FavoriteRoute> _favorites = [];

  // Offline cache
  bool _isShowingOfflineData = false;

  @override
  void initState() {
    super.initState();
    _determinePosition();
    _loadFavorites();
    _loadOfflineCache();

    _stopSearchController.addListener(() {
      setState(() => _stopSearchQuery = _stopSearchController.text);
      _rebuildStopMarkers();
    });
  }

  @override
  void dispose() {
    _liveBusTimer?.cancel();
    _stopSearchController.dispose();
    super.dispose();
  }

  // ─── Favorites ────────────────────────────────────────────────────────────
  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('favorites') ?? [];
    setState(() {
      _favorites = raw
          .map((s) => FavoriteRoute.fromJson(json.decode(s)))
          .toList();
    });
  }

  Future<void> _saveFavoritesToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = _favorites.map((f) => json.encode(f.toJson())).toList();
    await prefs.setStringList('favorites', raw);
  }

  void _toggleFavorite() {
    if (_destinationFeature == null) return;

    final destName = _destinationFeature!['name'] as String;
    final alreadySaved = _favorites.any((f) => f.destinationName == destName);

    setState(() {
      if (alreadySaved) {
        _favorites.removeWhere((f) => f.destinationName == destName);
        _showSnack('Reitti poistettu suosikeista.');
      } else {
        _favorites.insert(
          0,
          FavoriteRoute(
            destinationName: destName,
            destLat: (_destinationFeature!['lat'] as num).toDouble(),
            destLon: (_destinationFeature!['lon'] as num).toDouble(),
            startName: _customStartFeature?['name'],
            startLat: (_customStartFeature?['lat'] as num?)?.toDouble(),
            startLon: (_customStartFeature?['lon'] as num?)?.toDouble(),
            savedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        _showSnack('Reitti tallennettu suosikkeihin!');
      }
    });
    _saveFavoritesToPrefs();
  }

  bool get _isCurrentDestinationFavorite {
    if (_destinationFeature == null) return false;
    final destName = _destinationFeature!['name'] as String;
    return _favorites.any((f) => f.destinationName == destName);
  }

  void _showFavoritesSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setModalState) => Column(
          mainAxisSize: MainAxisSize.min,
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
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Row(
                children: [
                  Icon(Icons.star_rounded, color: kAccent),
                  SizedBox(width: 10),
                  Text(
                    'Suosikkireittisi',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: kPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            if (_favorites.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Ei tallennettuja reittejä.\nTallenna reitti tähti-painikkeella reittikortin oikeasta yläkulmasta.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _favorites.length,
                  itemBuilder: (_, index) {
                    final fav = _favorites[index];
                    return ListTile(
                      leading: const Icon(Icons.star_rounded, color: kAccent),
                      title: Text(
                        fav.destinationName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Row(
                        children: [
                          const Icon(Icons.trip_origin, size: 11, color: kWalk),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              fav.startName ?? 'Nykyinen sijainti',
                              style: const TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Icon(
                            Icons.arrow_forward,
                            size: 11,
                            color: Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.location_on,
                            size: 11,
                            color: kPrimary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              fav.destinationName,
                              style: const TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                        ),
                        onPressed: () {
                          setState(() => _favorites.removeAt(index));
                          setModalState(() {});
                          _saveFavoritesToPrefs();
                        },
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        setState(() {
                          _destinationFeature = {
                            'name': fav.destinationName,
                            'lat': fav.destLat,
                            'lon': fav.destLon,
                          };
                          if (fav.startLat != null) {
                            _customStartFeature = {
                              'name': fav.startName ?? '',
                              'lat': fav.startLat!,
                              'lon': fav.startLon!,
                            };
                          }
                        });
                        searchRoute();
                      },
                    );
                  },
                ),
              ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
          ],
        ),
      ),
    );
  }

  // ─── Offline cache ────────────────────────────────────────────────────────
  Future<void> _loadOfflineCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString('last_route_options');
      final cachedDestName = prefs.getString('last_dest_name');
      final cachedDestLat = prefs.getDouble('last_dest_lat');
      final cachedDestLon = prefs.getDouble('last_dest_lon');

      if (cachedJson != null && cachedDestLat != null && mounted) {
        final List<dynamic> rawList = json.decode(cachedJson);
        final options = rawList
            .map((item) => RouteOption.fromJson(item as Map<String, dynamic>))
            .toList();

        if (options.isNotEmpty) {
          setState(() {
            _routeOptions = options;
            _selectedRouteIndex = 0;
            _isShowingOfflineData = true;
            if (cachedDestName != null) {
              _destinationFeature = {
                'name': cachedDestName,
                'lat': cachedDestLat,
                'lon': cachedDestLon ?? 0.0,
              };
            }
          });
        }
      }
    } catch (e) {
      debugPrint('Offline cache load error: $e');
    }
  }

  Future<void> _saveOfflineCache() async {
    if (_routeOptions.isEmpty || _destinationFeature == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = json.encode(
        _routeOptions.map((r) => r.toJson()).toList(),
      );
      await prefs.setString('last_route_options', jsonStr);
      await prefs.setString(
        'last_dest_name',
        _destinationFeature!['name'] ?? '',
      );
      await prefs.setDouble(
        'last_dest_lat',
        (_destinationFeature!['lat'] as num).toDouble(),
      );
      await prefs.setDouble(
        'last_dest_lon',
        (_destinationFeature!['lon'] as num).toDouble(),
      );
    } catch (e) {
      debugPrint('Offline cache save error: $e');
    }
  }

  // ─── Share route ──────────────────────────────────────────────────────────
  void _shareRoute(RouteOption option) {
    final buf = StringBuffer();
    buf.writeln('🚌 Pohjoisen Reitit');
    buf.writeln('Lähde klo ${_formatTime(option.leaveHomeTime)}');

    for (final leg in option.busLegs) {
      buf.writeln(
        '→ Linja ${leg.busNumber}: ${leg.fromStop} → ${leg.toStop} (klo ${_formatTime(leg.departureTime)})',
      );
    }

    buf.writeln('Perillä klo ${_formatTime(option.arrivalTime)}');
    buf.writeln(
      'Matka-aika: ${option.arrivalTime.difference(option.leaveHomeTime).inMinutes} min',
    );

    Clipboard.setData(ClipboardData(text: buf.toString()));
    _showSnack('Reittitiedot kopioitu leikepöydälle!');
  }

  // ─── Stop display ─────────────────────────────────────────────────────────
  void _rebuildStopMarkers() {
    final query = _stopSearchQuery.toLowerCase();
    final filtered = query.isEmpty
        ? _rawStops
        : _rawStops
              .where((s) => (s['name'] as String).toLowerCase().contains(query))
              .toList();

    setState(() {
      _stopMarkers = filtered.map((stop) => _buildStopMarker(stop)).toList();
    });
  }

  Marker _buildStopMarker(Map<String, dynamic> stop) {
    return Marker(
      point: LatLng(
        (stop['lat'] as num).toDouble(),
        (stop['lon'] as num).toDouble(),
      ),
      width: 15,
      height: 15,
      child: GestureDetector(
        onTap: () => _showStopOptions(stop),
        child: _StopDot(stop['name'] ?? ''),
      ),
    );
  }

  void _showStopOptions(Map<String, dynamic> stop) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.transfer_within_a_station, color: kStop),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      stop['name'] ?? '',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: kStop,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.schedule, color: kBus),
              title: const Text('Näytä aikataulu'),
              onTap: () {
                Navigator.pop(ctx);
                _openStopBoard(stop);
              },
            ),
            ListTile(
              leading: const Icon(Icons.trip_origin, color: kWalk),
              title: const Text('Aseta lähtöpisteeksi'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _customStartFeature = {
                    'name': stop['name'],
                    'lat': (stop['lat'] as num).toDouble(),
                    'lon': (stop['lon'] as num).toDouble(),
                  };
                });
                if (_destinationFeature != null) searchRoute();
              },
            ),
            ListTile(
              leading: const Icon(Icons.location_on, color: kPrimary),
              title: const Text('Aseta määränpääksi'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _destinationFeature = {
                    'name': stop['name'],
                    'lat': (stop['lat'] as num).toDouble(),
                    'lon': (stop['lon'] as num).toDouble(),
                  };
                  _showSearchPanel = false;
                });
                searchRoute();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _openStopBoard(Map<String, dynamic> stop) {
    final stopLat = (stop['lat'] as num).toDouble();
    final stopLon = (stop['lon'] as num).toDouble();
    final stopName = stop['name'] as String? ?? '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (ctx2, scrollController) => _StopBoardSheet(
          stopId: stop['gtfsId'] ?? '',
          stopName: stopName,
          digitransitKey: _digitransitKey,
          formatTime: _formatTime,
          scrollController: scrollController,
          onSetAsStart: () {
            Navigator.pop(ctx);
            setState(() {
              _customStartFeature = {
                'name': stopName,
                'lat': stopLat,
                'lon': stopLon,
              };
            });
            if (_destinationFeature != null) searchRoute();
          },
          onSetAsDestination: () {
            Navigator.pop(ctx);
            setState(() {
              _destinationFeature = {
                'name': stopName,
                'lat': stopLat,
                'lon': stopLon,
              };
              _showSearchPanel = false;
            });
            searchRoute();
          },
        ),
      ),
    );
  }

  // ─── Snackbar ─────────────────────────────────────────────────────────────
  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(12),
      ),
    );
  }

  // ─── Live tracking ────────────────────────────────────────────────────────
  void _toggleLiveTracking() {
    setState(() => _isLiveTrackingActive = !_isLiveTrackingActive);

    if (_isLiveTrackingActive) {
      fetchLiveBuses(showSnack: true);
      _liveBusTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
        fetchLiveBuses(showSnack: false);
      });
    } else {
      _liveBusTimer?.cancel();
      setState(() => _busMarkers = []);
      _showSnack('Reaaliaikainen seuranta sammutettu.');
    }
  }

  // ─── Location ─────────────────────────────────────────────────────────────
  Future<void> _determinePosition() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      _showSnack(
        'Sijainti ei tuettu tällä alustalla, käytetään Oulun keskustaa.',
      );
      return;
    }

    bool serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showSnack('Sijaintipalvelut ovat pois päältä.');
      return;
    }

    geo.LocationPermission permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
      if (permission == geo.LocationPermission.denied) {
        _showSnack('Sijaintilupa evätty.');
        return;
      }
    }

    if (permission == geo.LocationPermission.deniedForever) {
      _showSnack('Sijaintilupa pysyvästi evätty.');
      return;
    }

    try {
      geo.Position position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
        ),
      );
      setState(() {
        _currentLocation = LatLng(position.latitude, position.longitude);
        _hasRealLocation = true;
      });
      _mapController.move(_currentLocation, 14.0);
    } catch (e) {
      _showSnack('Virhe sijainnin haussa: $e');
    }
  }

  void _resetToCurrentLocation() {
    setState(() {
      _customStartFeature = null;
      _departureTime = DateTime.now();
    });
    _mapController.move(_currentLocation, 14.0);
    if (_destinationFeature != null) searchRoute();
  }

  void _swapLocations() {
    setState(() {
      final temp = _customStartFeature;
      _customStartFeature = _destinationFeature;
      _destinationFeature = temp;
    });
    if (_destinationFeature != null) searchRoute();
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  void _zoomToRoute(int index) {
    final allPoints = _routeOptions[index].segments
        .expand((s) => s.points)
        .toList();
    if (allPoints.isNotEmpty) {
      final bounds = LatLngBounds.fromPoints(allPoints);
      _mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(100)),
      );
    }
  }

  void _updateBusMarkers() {
    if (_latestFeedMessage == null || !_isLiveTrackingActive) return;

    final Set<String> activeRouteIds = {};
    final Set<String> activeBusNumbers = {};

    if (_routeOptions.isNotEmpty) {
      for (var leg in _routeOptions[_selectedRouteIndex].busLegs) {
        activeBusNumbers.add(leg.busNumber);
        String rId = leg.routeGtfsId;
        if (rId.contains(':')) rId = rId.split(':').last;
        if (rId.isNotEmpty) activeRouteIds.add(rId);
      }
    }

    List<Marker> markers = [];

    for (var entity in _latestFeedMessage!.entity) {
      if (!entity.hasVehicle()) continue;
      final vehicle = entity.vehicle;
      if (!vehicle.hasPosition() || !vehicle.hasTrip()) continue;

      final routeId = vehicle.trip.routeId;
      final pos = vehicle.position;

      bool matches =
          _routeOptions.isEmpty ||
          activeRouteIds.contains(routeId) ||
          activeBusNumbers.contains(routeId) ||
          activeBusNumbers.any(
            (busNum) =>
                routeId.endsWith(':$busNum') ||
                routeId.endsWith('_$busNum') ||
                routeId == busNum,
          );

      if (!matches) continue;

      String displayNumber = routeId;
      if (_routeOptions.isNotEmpty) {
        for (var leg in _routeOptions[_selectedRouteIndex].busLegs) {
          String rId = leg.routeGtfsId.contains(':')
              ? leg.routeGtfsId.split(':').last
              : leg.routeGtfsId;
          if (routeId == rId ||
              routeId == leg.busNumber ||
              routeId.endsWith(leg.busNumber)) {
            displayNumber = leg.busNumber;
            break;
          }
        }
      } else {
        if (routeId.contains(':')) displayNumber = routeId.split(':').last;
        if (routeId.contains('_')) displayNumber = routeId.split('_').last;
      }

      markers.add(
        Marker(
          point: LatLng(pos.latitude, pos.longitude),
          width: 42,
          height: 52,
          child: _LiveBusMarker(displayNumber),
        ),
      );
    }

    setState(() => _busMarkers = markers);
  }

  // ─── Nearby stops ─────────────────────────────────────────────────────────
  Future<void> _fetchNearbyStops() async {
    if (_isFetchingStops) return;
    _isFetchingStops = true;

    try {
      final camera = _mapController.camera;
      final bounds = camera.visibleBounds;

      final String query =
          """
            {
              stopsByBbox(
                minLat: ${bounds.south}, minLon: ${bounds.west},
                maxLat: ${bounds.north}, maxLon: ${bounds.east}
              ) {
                gtfsId name lat lon
              }
            }
            """;

      final response = await http.post(
        Uri.parse('https://api.digitransit.fi/routing/v2/waltti/gtfs/v1'),
        headers: {
          'Content-Type': 'application/json',
          'digitransit-subscription-key': _digitransitKey,
        },
        body: json.encode({'query': query}),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final stops = data['data']?['stopsByBbox'] as List<dynamic>?;

        if (stops != null && mounted) {
          setState(() {
            _rawStops = stops.map((s) => Map<String, dynamic>.from(s)).toList();
          });
          _rebuildStopMarkers();
        }
      }
    } catch (e) {
      debugPrint('Error fetching stops: $e');
    } finally {
      _isFetchingStops = false;
    }
  }

  List<Marker> _buildRouteStopMarkers() {
    if (_routeOptions.isEmpty) return [];
    final route = _routeOptions[_selectedRouteIndex];
    final List<Marker> markers = [];

    for (final leg in route.busLegs) {
      if (leg.fromLat != null && leg.fromLon != null) {
        markers.add(
          Marker(
            point: LatLng(leg.fromLat!, leg.fromLon!),
            width: 22,
            height: 22,
            child: _BoardingStopMarker(leg.fromStop),
          ),
        );
      }
      for (final stop in leg.intermediateStops) {
        markers.add(
          Marker(
            point: LatLng(stop.lat, stop.lon),
            width: 11,
            height: 11,
            child: _IntermediateStopDot(stop.name),
          ),
        );
      }
      if (leg.toLat != null && leg.toLon != null) {
        markers.add(
          Marker(
            point: LatLng(leg.toLat!, leg.toLon!),
            width: 22,
            height: 22,
            child: _AlightingStopMarker(leg.toStop),
          ),
        );
      }
    }
    return markers;
  }

  Future<void> _pickDepartureDateTime() async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: _departureTime,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 30)),
    );
    if (pickedDate == null || !mounted) return;

    final TimeOfDay? pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _departureTime.hour,
        minute: _departureTime.minute,
      ),
    );
    if (pickedTime == null) return;

    setState(() {
      _departureTime = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });

    if (_destinationFeature != null) searchRoute();
  }

  // ─── Autocomplete ─────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> _getAutocompleteSuggestions(
    String query,
  ) async {
    if (query.isEmpty) return _recentSearches;

    try {
      final response = await http.get(
        Uri.parse(
          'https://api.digitransit.fi/geocoding/v1/autocomplete?text=$query'
          '&boundary.rect.min_lat=64.7&boundary.rect.max_lat=65.45'
          '&boundary.rect.min_lon=24.9&boundary.rect.max_lon=26.5',
        ),
        headers: {'digitransit-subscription-key': _digitransitKey},
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final features = data['features'] as List<dynamic>;
        return features
            .map(
              (f) => {
                'name': f['properties']['name'],
                'label': f['properties']['label'],
                'lat': f['geometry']['coordinates'][1],
                'lon': f['geometry']['coordinates'][0],
              },
            )
            .toList();
      }
    } catch (e) {
      debugPrint('Autocomplete error: $e');
    }
    return [];
  }

  void _addToHistory(Map<String, dynamic> feature) {
    setState(() {
      _recentSearches.removeWhere((item) => item['name'] == feature['name']);
      _recentSearches.insert(0, feature);
      if (_recentSearches.length > 5) _recentSearches.removeLast();
    });
  }

  // ─── Route search ─────────────────────────────────────────────────────────
  Future<void> searchRoute() async {
    if (_destinationFeature == null) return;

    setState(() {
      _isLoading = true;
      _routeOptions.clear();
      _showSearchPanel = false;
      _isShowingOfflineData = false;
    });
    FocusScope.of(context).unfocus();

    await fetchRoutes(_destinationFeature!['lat'], _destinationFeature!['lon']);

    setState(() => _isLoading = false);
  }

  Future<void> fetchRoutes(
    double destLat,
    double destLon, {
    bool isFallback = false,
  }) async {
    final routeUrl = Uri.parse(
      'https://api.digitransit.fi/routing/v2/waltti/gtfs/v1',
    );
    final startLat = _customStartFeature?['lat'] ?? _currentLocation.latitude;
    final startLon = _customStartFeature?['lon'] ?? _currentLocation.longitude;
    final int searchWindow = isFallback ? 86400 : 10800;

    final String baseQuery =
        """
        {
          plan(
            from: {lat: $startLat, lon: $startLon},
            to: {lat: $destLat, lon: $destLon},
            numItineraries: 10,
            searchWindow: $searchWindow,
            walkSpeed: ${_walkSpeedMS.toStringAsFixed(2)},
            walkReluctance: 1.0,
            minTransferTime: $_minTransferTime,
            date: "${_departureTime.year}-${_departureTime.month.toString().padLeft(2, '0')}-${_departureTime.day.toString().padLeft(2, '0')}",
            time: "${_departureTime.hour.toString().padLeft(2, '0')}:${_departureTime.minute.toString().padLeft(2, '0')}:00",
            arriveBy: false
          ) {
            itineraries {
              startTime endTime
              legs {
                mode startTime endTime distance
                route { shortName gtfsId alerts { alertHeaderText } }
                from { name lat lon stop { gtfsId } }
                to { name lat lon }
                legGeometry { points }
                intermediateStops { name lat lon }
              }
            }
          }
        }
        """;

    try {
      final response = await http.post(
        routeUrl,
        headers: {
          'Content-Type': 'application/json',
          'digitransit-subscription-key': _digitransitKey,
        },
        body: json.encode({'query': baseQuery}),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['data'] == null ||
            data['data']['plan'] == null ||
            data['data']['plan']['itineraries'].isEmpty) {
          if (!isFallback) {
            _showSnack(
              'Ei lähtöjä lähiaikoina. Etsitään seuraavaa mahdollista...',
            );
            await fetchRoutes(destLat, destLon, isFallback: true);
          } else {
            _showSnack('Reittiä ei löytynyt seuraavaan 24 tuntiin.');
          }
          return;
        }

        final itineraries = data['data']['plan']['itineraries'];

        if (isFallback) {
          final nextTime = DateTime.fromMillisecondsSinceEpoch(
            itineraries[0]['startTime'],
          );
          setState(
            () =>
                _departureTime = nextTime.subtract(const Duration(minutes: 10)),
          );
          await fetchRoutes(destLat, destLon, isFallback: false);
          return;
        }

        List<RouteOption> parsedOptions = [];

        for (var itinerary in itineraries) {
          DateTime leaveHome = DateTime.fromMillisecondsSinceEpoch(
            itinerary['startTime'],
          );
          DateTime arrival = DateTime.fromMillisecondsSinceEpoch(
            itinerary['endTime'],
          );

          List<RouteSegment> segments = [];
          List<BusLeg> busLegs = [];
          List<double> walkDistances = [];

          for (var leg in itinerary['legs']) {
            if (leg['mode'] == 'WALK') {
              walkDistances.add((leg['distance'] as num).toDouble());
            }

            if (leg['mode'] == 'BUS') {
              String stopId = leg['from']?['stop']?['gtfsId'] ?? '';
              DateTime scheduledDep = DateTime.fromMillisecondsSinceEpoch(
                leg['startTime'],
              );

              double? fromLat = (leg['from']?['lat'] as num?)?.toDouble();
              double? fromLon = (leg['from']?['lon'] as num?)?.toDouble();
              double? toLat = (leg['to']?['lat'] as num?)?.toDouble();
              double? toLon = (leg['to']?['lon'] as num?)?.toDouble();

              List<IntermediateStop> intermediateStops = [];
              final rawStops = leg['intermediateStops'] as List<dynamic>?;
              if (rawStops != null) {
                for (var s in rawStops) {
                  if (s['lat'] != null && s['lon'] != null) {
                    intermediateStops.add(
                      IntermediateStop(
                        name: s['name'] ?? '',
                        lat: (s['lat'] as num).toDouble(),
                        lon: (s['lon'] as num).toDouble(),
                      ),
                    );
                  }
                }
              }

              // Parse alerts
              List<AlertInfo> alerts = [];
              final rawAlerts = leg['route']?['alerts'] as List<dynamic>?;
              if (rawAlerts != null) {
                for (var a in rawAlerts) {
                  final text = a['alertHeaderText'];
                  if (text != null && text.toString().isNotEmpty) {
                    alerts.add(AlertInfo(text: text.toString()));
                  }
                }
              }

              busLegs.add(
                BusLeg(
                  busNumber: leg['route']['shortName'] ?? 'Bussi',
                  routeGtfsId: leg['route']['gtfsId'] ?? '',
                  fromStop: leg['from']['name'] ?? 'Tuntematon pysäkki',
                  fromStopId: stopId,
                  fromLat: fromLat,
                  fromLon: fromLon,
                  toStop: leg['to']['name'] ?? 'Tuntematon pysäkki',
                  toLat: toLat,
                  toLon: toLon,
                  departureTime: scheduledDep,
                  arrivalTime: DateTime.fromMillisecondsSinceEpoch(
                    leg['endTime'],
                  ),
                  realtimeDeparture: scheduledDep,
                  realtimeState: 'SCHEDULED',
                  isRealtime: false,
                  intermediateStops: intermediateStops,
                  alerts: alerts,
                ),
              );
            }

            if (leg['legGeometry']?['points'] != null) {
              List<PointLatLng> result = PolylinePoints.decodePolyline(
                leg['legGeometry']['points'],
              );
              final legPoints = result
                  .map((p) => LatLng(p.latitude, p.longitude))
                  .toList();
              if (legPoints.isNotEmpty) {
                segments.add(
                  RouteSegment(
                    points: legPoints,
                    isWalk: leg['mode'] == 'WALK',
                  ),
                );
              }
            }
          }

          parsedOptions.add(
            RouteOption(
              leaveHomeTime: leaveHome,
              arrivalTime: arrival,
              busLegs: busLegs,
              segments: segments,
              walkDistances: walkDistances,
            ),
          );
        }

        // ─ Timetable extension ────────────────────────────────────────
        Set<String> stopIdsToQuery = {};
        for (var opt in parsedOptions) {
          if (opt.busLegs.isNotEmpty &&
              opt.busLegs.first.fromStopId.isNotEmpty) {
            stopIdsToQuery.add(opt.busLegs.first.fromStopId);
          }
        }

        if (stopIdsToQuery.isNotEmpty) {
          String stopQueries = '';
          int i = 0;
          final startTimeSec = _departureTime.millisecondsSinceEpoch ~/ 1000;

          for (String stopId in stopIdsToQuery) {
            stopQueries +=
                """
                        stop$i: stop(id: "$stopId") {
                          gtfsId
                          stoptimesWithoutPatterns(startTime: $startTimeSec, timeRange: 7200, numberOfDepartures: 30) {
                            scheduledDeparture realtimeDeparture realtimeState realtime serviceDay
                            trip { route { shortName } }
                          }
                        }
                        """;
            i++;
          }

          try {
            final ttResponse = await http.post(
              routeUrl,
              headers: {
                'Content-Type': 'application/json',
                'digitransit-subscription-key': _digitransitKey,
              },
              body: json.encode({'query': '{ $stopQueries }'}),
            );

            if (ttResponse.statusCode == 200) {
              final ttData = json.decode(ttResponse.body);
              final ttDataMap = ttData['data'] as Map<String, dynamic>?;

              if (ttDataMap != null) {
                Map<String, List<StopTimeData>> timetableMap = {};

                ttDataMap.forEach((alias, stopData) {
                  if (stopData != null && stopData['gtfsId'] != null) {
                    String sId = stopData['gtfsId'];
                    var stoptimes =
                        stopData['stoptimesWithoutPatterns'] as List<dynamic>?;

                    if (stoptimes != null) {
                      for (var st in stoptimes) {
                        String? rName = st['trip']?['route']?['shortName'];
                        int? schedDep = st['scheduledDeparture'];
                        int? realDep = st['realtimeDeparture'];
                        int? serviceDay = st['serviceDay'];
                        String rtState = st['realtimeState'] ?? 'SCHEDULED';
                        bool isRt = st['realtime'] ?? false;

                        if (rName != null &&
                            schedDep != null &&
                            serviceDay != null) {
                          String key = '${sId}_$rName';
                          timetableMap
                              .putIfAbsent(key, () => [])
                              .add(
                                StopTimeData(
                                  scheduledEpochSec: serviceDay + schedDep,
                                  realtimeEpochSec:
                                      serviceDay + (realDep ?? schedDep),
                                  realtimeState: rtState,
                                  isRealtime: isRt,
                                ),
                              );
                        }
                      }
                    }
                  }
                });

                List<RouteOption> expandedOptions = [];
                Set<String> addedSignatures = {};

                for (var opt in parsedOptions) {
                  if (opt.busLegs.isEmpty) {
                    String sig =
                        'walk_only_${(opt.arrivalTime.millisecondsSinceEpoch / 600000).round()}';
                    if (!addedSignatures.contains(sig)) {
                      addedSignatures.add(sig);
                      expandedOptions.add(opt);
                    }
                    continue;
                  }

                  var firstLeg = opt.busLegs.first;
                  String key = '${firstLeg.fromStopId}_${firstLeg.busNumber}';

                  if (timetableMap.containsKey(key)) {
                    for (var stData in timetableMap[key]!) {
                      DateTime newScheduledDep =
                          DateTime.fromMillisecondsSinceEpoch(
                            stData.scheduledEpochSec * 1000,
                          );
                      Duration offset = newScheduledDep.difference(
                        firstLeg.departureTime,
                      );

                      List<BusLeg> clonedLegs = [];
                      for (int k = 0; k < opt.busLegs.length; k++) {
                        var baseLeg = opt.busLegs[k];
                        DateTime legRealDep = baseLeg.departureTime.add(offset);
                        String state = 'SCHEDULED';
                        bool isRt = false;

                        if (k == 0) {
                          legRealDep = DateTime.fromMillisecondsSinceEpoch(
                            stData.realtimeEpochSec * 1000,
                          );
                          state = stData.realtimeState;
                          isRt = stData.isRealtime;
                        }

                        clonedLegs.add(
                          BusLeg(
                            busNumber: baseLeg.busNumber,
                            routeGtfsId: baseLeg.routeGtfsId,
                            fromStop: baseLeg.fromStop,
                            fromStopId: baseLeg.fromStopId,
                            fromLat: baseLeg.fromLat,
                            fromLon: baseLeg.fromLon,
                            toStop: baseLeg.toStop,
                            toLat: baseLeg.toLat,
                            toLon: baseLeg.toLon,
                            departureTime: baseLeg.departureTime.add(offset),
                            arrivalTime: baseLeg.arrivalTime.add(offset),
                            realtimeDeparture: legRealDep,
                            realtimeState: state,
                            isRealtime: isRt,
                            intermediateStops: baseLeg.intermediateStops,
                            alerts: baseLeg.alerts,
                          ),
                        );
                      }

                      String sig = clonedLegs
                          .map(
                            (l) =>
                                '${l.busNumber}_${l.departureTime.millisecondsSinceEpoch}',
                          )
                          .join('|');

                      if (!addedSignatures.contains(sig)) {
                        addedSignatures.add(sig);
                        Duration firstLegDelay = clonedLegs
                            .first
                            .realtimeDeparture
                            .difference(clonedLegs.first.departureTime);
                        expandedOptions.add(
                          RouteOption(
                            leaveHomeTime: opt.leaveHomeTime.add(offset),
                            arrivalTime: opt.arrivalTime
                                .add(offset)
                                .add(firstLegDelay),
                            busLegs: clonedLegs,
                            segments: opt.segments,
                            walkDistances: opt.walkDistances,
                          ),
                        );
                      }
                    }
                  } else {
                    String sig = opt.busLegs
                        .map(
                          (l) =>
                              '${l.busNumber}_${l.departureTime.millisecondsSinceEpoch}',
                        )
                        .join('|');
                    if (!addedSignatures.contains(sig)) {
                      addedSignatures.add(sig);
                      expandedOptions.add(opt);
                    }
                  }
                }
                parsedOptions = expandedOptions;
              }
            }
          } catch (e) {
            debugPrint('Timetable extension failed: $e');
          }
        }

        parsedOptions.sort(
          (a, b) => a.leaveHomeTime.compareTo(b.leaveHomeTime),
        );

        setState(() {
          _routeOptions = parsedOptions;
          _selectedRouteIndex = 0;
        });
        _updateBusMarkers();
        _saveOfflineCache();

        if (parsedOptions.isNotEmpty) {
          final allPoints = parsedOptions[0].segments
              .expand((s) => s.points)
              .toList();
          if (allPoints.isNotEmpty) {
            final bounds = LatLngBounds.fromPoints(allPoints);
            _mapController.fitCamera(
              CameraFit.bounds(
                bounds: bounds,
                padding: const EdgeInsets.all(100),
              ),
            );
          }
        }
      } else {
        _showSnack('Virhe API-yhteydessä: ${response.statusCode}');
      }
    } catch (e) {
      _showSnack('Virhe reitin haussa: $e');
    }
  }

  Future<void> fetchLiveBuses({bool showSnack = true}) async {
    // FIX: prevent concurrent fetches
    if (_isFetchingLiveBuses) return;
    _isFetchingLiveBuses = true;

    final String encodedCredentials = base64Encode(
      utf8.encode('$_walttiClientId:$_walttiClientSecret'),
    );
    try {
      final response = await http.get(
        Uri.parse(
          'https://data.waltti.fi/oulu/api/gtfsrealtime/v1.0/feed/vehicleposition',
        ),
        headers: {'Authorization': 'Basic $encodedCredentials'},
      );
      if (response.statusCode == 200) {
        _latestFeedMessage = FeedMessage.fromBuffer(response.bodyBytes);
        _updateBusMarkers();
        if (showSnack) {
          _showSnack(
            'Live-sijainnit päivitetty (${_busMarkers.length} bussia näkyvissä)',
          );
        }
      } else {
        if (showSnack) {
          _showSnack('Virhe Waltti-yhteydessä: ${response.statusCode}');
        }
      }
    } catch (e) {
      if (showSnack) {
        _showSnack('Virhe Waltti-haussa: $e');
      }
    } finally {
      _isFetchingLiveBuses = false;
    }
  }

  Future<void> _showSettingsDialog() async {
    int tempTransferTime = _minTransferTime;
    double tempWalkSpeed = _walkSpeedKmH;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Hakuasetukset'),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Minimivaihtoaika:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              DropdownButton<int>(
                value: tempTransferTime,
                isExpanded: true,
                borderRadius: BorderRadius.circular(12),
                items: const [
                  DropdownMenuItem(value: 90, child: Text('1.5 min')),
                  DropdownMenuItem(value: 120, child: Text('2 min')),
                  DropdownMenuItem(value: 180, child: Text('3 min')),
                  DropdownMenuItem(value: 300, child: Text('5 min')),
                  DropdownMenuItem(value: 600, child: Text('10 min')),
                ],
                onChanged: (val) {
                  if (val != null) setDialogState(() => tempTransferTime = val);
                },
              ),
              const SizedBox(height: 20),
              Text(
                'Kävelyvauhti: ${tempWalkSpeed.toStringAsFixed(1)} km/h',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Slider(
                value: tempWalkSpeed,
                min: 2.0,
                max: 10.0,
                divisions: 16,
                activeColor: kPrimary,
                label: '${tempWalkSpeed.toStringAsFixed(1)} km/h',
                onChanged: (val) => setDialogState(() => tempWalkSpeed = val),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Peruuta'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kPrimary),
              onPressed: () {
                setState(() {
                  _minTransferTime = tempTransferTime;
                  _walkSpeedKmH = tempWalkSpeed;
                });
                Navigator.pop(context);
                if (_destinationFeature != null) searchRoute();
              },
              child: const Text('Tallenna'),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Search panel ─────────────────────────────────────────────────────────
  Widget _buildSearchPanel() {
    final now = DateTime.now();
    final bool isToday =
        _departureTime.year == now.year &&
        _departureTime.month == now.month &&
        _departureTime.day == now.day;
    final String timeLabel = isToday
        ? 'Tänään ${_formatTime(_departureTime)}'
        : '${_formatDate(_departureTime)} klo ${_formatTime(_departureTime)}';

    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
      child: _showSearchPanel
          ? Card(
              elevation: 6,
              shadowColor: Colors.black26,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  // Start field
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 4, 6),
                    child: Row(
                      children: [
                        const Icon(Icons.trip_origin, color: kWalk, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Autocomplete<Map<String, dynamic>>(
                            initialValue: TextEditingValue(
                              text: _customStartFeature?['name'] ?? '',
                            ),
                            optionsBuilder:
                                (TextEditingValue textEditingValue) async {
                                  return await _getAutocompleteSuggestions(
                                    textEditingValue.text,
                                  );
                                },
                            displayStringForOption: (option) => option['name'],
                            onSelected: (option) {
                              setState(() => _customStartFeature = option);
                              _addToHistory(option);
                              if (_destinationFeature != null) searchRoute();
                            },
                            fieldViewBuilder:
                                (
                                  context,
                                  controller,
                                  focusNode,
                                  onFieldSubmitted,
                                ) {
                                  // FIX: only update controller when user is not actively typing
                                  if (!focusNode.hasFocus) {
                                    final expected =
                                        _customStartFeature?['name'] ?? '';
                                    if (controller.text != expected) {
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                            if (mounted &&
                                                !focusNode.hasFocus) {
                                              controller.text = expected;
                                            }
                                          });
                                    }
                                  }
                                  return TextField(
                                    controller: controller,
                                    focusNode: focusNode,
                                    style: const TextStyle(fontSize: 14),
                                    decoration: const InputDecoration(
                                      hintText: 'Lähtöpiste (tyhjä = GPS)',
                                      hintStyle: TextStyle(color: Colors.grey),
                                      border: InputBorder.none,
                                      isDense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  );
                                },
                            optionsViewBuilder: (context, onSelected, options) {
                              return Align(
                                alignment: Alignment.topLeft,
                                child: Material(
                                  elevation: 4,
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    width:
                                        MediaQuery.of(context).size.width - 100,
                                    constraints: const BoxConstraints(
                                      maxHeight: 250,
                                    ),
                                    child: ListView.builder(
                                      padding: EdgeInsets.zero,
                                      shrinkWrap: true,
                                      itemCount: options.length,
                                      itemBuilder:
                                          (BuildContext context, int index) {
                                            final option = options.elementAt(
                                              index,
                                            );
                                            final isHistory = _recentSearches
                                                .contains(option);
                                            return ListTile(
                                              leading: Icon(
                                                isHistory
                                                    ? Icons.history
                                                    : Icons.place,
                                                color: Colors.grey,
                                              ),
                                              title: Text(option['name']),
                                              subtitle: option['label'] != null
                                                  ? Text(
                                                      option['label'],
                                                      style: const TextStyle(
                                                        fontSize: 11,
                                                      ),
                                                    )
                                                  : null,
                                              onTap: () => onSelected(option),
                                            );
                                          },
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.my_location,
                            color: _customStartFeature == null
                                ? kBus
                                : Colors.grey,
                            size: 20,
                          ),
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Käytä nykyistä sijaintia',
                          onPressed: _resetToCurrentLocation,
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.map_outlined,
                            color: _isSelectingStart ? kWalk : Colors.grey,
                            size: 20,
                          ),
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            setState(
                              () => _isSelectingStart = !_isSelectingStart,
                            );
                            if (_isSelectingStart) {
                              _showSnack('Napauta kartalta lähtöpiste!');
                            }
                          },
                        ),
                      ],
                    ),
                  ),

                  // Swap button
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _swapLocations,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: kSurface,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.grey[300]!),
                            ),
                            child: const Icon(
                              Icons.swap_vert,
                              size: 16,
                              color: kBus,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Container(
                            height: 1,
                            color: const Color(0xFFEEEEEE),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Destination field
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 4, 10),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.location_on,
                          color: kPrimary,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Autocomplete<Map<String, dynamic>>(
                            initialValue: TextEditingValue(
                              text: _destinationFeature?['name'] ?? '',
                            ),
                            optionsBuilder:
                                (TextEditingValue textEditingValue) async {
                                  return await _getAutocompleteSuggestions(
                                    textEditingValue.text,
                                  );
                                },
                            displayStringForOption: (option) => option['name'],
                            onSelected: (option) {
                              setState(() => _destinationFeature = option);
                              _addToHistory(option);
                              searchRoute();
                            },
                            fieldViewBuilder:
                                (
                                  context,
                                  controller,
                                  focusNode,
                                  onFieldSubmitted,
                                ) {
                                  // FIX: only update controller when user is not actively typing
                                  if (!focusNode.hasFocus) {
                                    final expected =
                                        _destinationFeature?['name'] ?? '';
                                    if (controller.text != expected) {
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                            if (mounted &&
                                                !focusNode.hasFocus) {
                                              controller.text = expected;
                                            }
                                          });
                                    }
                                  }
                                  return TextField(
                                    controller: controller,
                                    focusNode: focusNode,
                                    style: const TextStyle(fontSize: 14),
                                    decoration: const InputDecoration(
                                      hintText: 'Syötä kohde Oulussa...',
                                      hintStyle: TextStyle(color: Colors.grey),
                                      border: InputBorder.none,
                                      isDense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  );
                                },
                            optionsViewBuilder: (context, onSelected, options) {
                              return Align(
                                alignment: Alignment.topLeft,
                                child: Material(
                                  elevation: 4,
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    width:
                                        MediaQuery.of(context).size.width - 100,
                                    constraints: const BoxConstraints(
                                      maxHeight: 250,
                                    ),
                                    child: ListView.builder(
                                      padding: EdgeInsets.zero,
                                      shrinkWrap: true,
                                      itemCount: options.length,
                                      itemBuilder:
                                          (BuildContext context, int index) {
                                            final option = options.elementAt(
                                              index,
                                            );
                                            final isHistory = _recentSearches
                                                .contains(option);
                                            return ListTile(
                                              leading: Icon(
                                                isHistory
                                                    ? Icons.history
                                                    : Icons.place,
                                                color: Colors.grey,
                                              ),
                                              title: Text(option['name']),
                                              subtitle: option['label'] != null
                                                  ? Text(
                                                      option['label'],
                                                      style: const TextStyle(
                                                        fontSize: 11,
                                                      ),
                                                    )
                                                  : null,
                                              onTap: () => onSelected(option),
                                            );
                                          },
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        _isLoading
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: kPrimary,
                                  ),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(
                                  Icons.search,
                                  color: kPrimary,
                                  size: 22,
                                ),
                                visualDensity: VisualDensity.compact,
                                onPressed: searchRoute,
                              ),
                      ],
                    ),
                  ),

                  // Favorites star button
                  if (_favorites.isNotEmpty) ...[
                    const Divider(height: 1, color: Color(0xFFEEEEEE)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      child: GestureDetector(
                        onTap: _showFavoritesSheet,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: kAccent.withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: kAccent.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.star_rounded,
                                size: 16,
                                color: kAccent,
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'Suosikit',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF664400),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: kAccent,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '${_favorites.length}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF3D2B00),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],

                  // Time picker
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: GestureDetector(
                      onTap: _pickDepartureDateTime,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: kSurface,
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(color: const Color(0xFFDDDDDD)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.schedule, size: 16, color: kBus),
                            const SizedBox(width: 6),
                            Text(
                              timeLabel,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: kBus,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.expand_more,
                              size: 16,
                              color: kBus,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  // ─── Stop search overlay ──────────────────────────────────────────────────
  Widget _buildStopSearchOverlay() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.search, color: kStop, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _stopSearchController,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'Suodata pysäkkejä nimellä...',
                hintStyle: TextStyle(color: Colors.grey, fontSize: 13),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (_stopSearchQuery.isNotEmpty)
            GestureDetector(
              onTap: () {
                _stopSearchController.clear();
                setState(() => _stopSearchQuery = '');
                _rebuildStopMarkers();
              },
              child: const Icon(Icons.close, color: Colors.grey, size: 16),
            ),
          if (_stopMarkers.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: kStop.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${_stopMarkers.length}',
                style: const TextStyle(
                  color: kStop,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── Route bottom sheet ───────────────────────────────────────────────────
  Widget _buildRouteSheet() {
    final screenHeight = MediaQuery.of(context).size.height;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final keyboardHeight = MediaQuery.of(
      context,
    ).viewInsets.bottom; // FIX: keyboard

    final double minVisiblePixels = 65.0 + bottomPadding;
    final double minSheetSize = (minVisiblePixels / screenHeight).clamp(
      0.1,
      0.3,
    );

    return AnimatedPadding(
      // FIX: push sheet up when keyboard appears
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.only(bottom: keyboardHeight),
      child: DraggableScrollableSheet(
        initialChildSize: 0.38,
        minChildSize: minSheetSize,
        maxChildSize: 0.72,
        snap: true,
        snapSizes: [minSheetSize, 0.38, 0.72],
        builder: (context, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 24,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: ListView(
              controller: scrollController,
              padding: EdgeInsets.zero,
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
                  padding: const EdgeInsets.fromLTRB(20, 4, 8, 8),
                  child: Row(
                    children: [
                      const Text(
                        'Reittivaihtoehdot',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF222222),
                        ),
                      ),
                      const Spacer(),
                      // Favorites button
                      GestureDetector(
                        onTap: _showFavoritesSheet,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: _favorites.isNotEmpty
                                ? kAccent.withValues(alpha: 0.15)
                                : kSurface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _favorites.isNotEmpty
                                  ? kAccent.withValues(alpha: 0.5)
                                  : Colors.transparent,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.star_rounded,
                                size: 16,
                                color: _favorites.isNotEmpty
                                    ? kAccent
                                    : Colors.grey,
                              ),
                              if (_favorites.isNotEmpty) ...[
                                const SizedBox(width: 4),
                                Text(
                                  '${_favorites.length}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF996600),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Offline indicator
                      if (_isShowingOfflineData)
                        Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.wifi_off,
                                size: 12,
                                color: Colors.orange,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Offline',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.orange,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_routeOptions.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: kPrimary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${_routeOptions.length} kpl',
                            style: const TextStyle(
                              color: kPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_isLoading)
                  for (int i = 0; i < 3; i++) const _ShimmerCard(),
                if (!_isLoading)
                  for (int i = 0; i < _routeOptions.length; i++)
                    _RouteCard(
                      option: _routeOptions[i],
                      isSelected: _selectedRouteIndex == i,
                      isFavorite: _isCurrentDestinationFavorite,
                      isOfflineData: _isShowingOfflineData,
                      formatTime: _formatTime,
                      onTap: () {
                        setState(() => _selectedRouteIndex = i);
                        _updateBusMarkers();
                        _zoomToRoute(i);
                      },
                      onToggleFavorite: _toggleFavorite,
                      onShare: () => _shareRoute(_routeOptions[i]),
                    ),
                SizedBox(height: 24 + MediaQuery.of(context).padding.bottom),
              ],
            ),
          );
        },
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final List<RouteSegment> currentSegments = _routeOptions.isNotEmpty
        ? _routeOptions[_selectedRouteIndex].segments
        : [];
    final List<Marker> routeStopMarkers = _buildRouteStopMarkers();

    return Scaffold(
      // FIX: explicit keyboard handling
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        toolbarHeight: 52,
        backgroundColor: kPrimary,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: const [
            Icon(Icons.directions_bus_filled, size: 22, color: Colors.white),
            SizedBox(width: 8),
            Text(
              'Pohjoisen Reitit',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 20,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.transfer_within_a_station,
              color: _showBusStops ? Colors.yellowAccent : Colors.white,
            ),
            tooltip: _showBusStops ? 'Piilota pysäkit' : 'Näytä pysäkit',
            onPressed: () async {
              setState(() => _showBusStops = !_showBusStops);
              if (_showBusStops) {
                await _fetchNearbyStops();
              } else {
                _stopSearchController.clear();
                setState(() {
                  _rawStops = [];
                  _stopMarkers = [];
                  _stopSearchQuery = '';
                });
              }
            },
          ),
          IconButton(
            icon: Icon(
              _showSearchPanel ? Icons.search_off : Icons.search,
              color: Colors.white,
            ),
            tooltip: _showSearchPanel ? 'Piilota haku' : 'Näytä haku',
            onPressed: () =>
                setState(() => _showSearchPanel = !_showSearchPanel),
          ),
          IconButton(
            icon: const Icon(Icons.tune, color: Colors.white),
            tooltip: 'Asetukset',
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentLocation,
              initialZoom: 13.0,
              onTap: (tapPosition, point) {
                if (_isSelectingStart) {
                  setState(() {
                    _customStartFeature = {
                      'name': '📍 Valittu kartalta',
                      'lat': point.latitude,
                      'lon': point.longitude,
                    };
                    _isSelectingStart = false;
                  });
                  _showSnack('Lähtöpiste asetettu kartalta!');
                  if (_destinationFeature != null) searchRoute();
                }
              },
              onMapEvent: (event) {
                if (_showBusStops && event is MapEventMoveEnd) {
                  _fetchNearbyStops();
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.pohjoisen_reitit',
              ),
              PolylineLayer(
                polylines: [
                  for (final segment in currentSegments)
                    Polyline(
                      points: segment.points,
                      strokeWidth: segment.isWalk ? 3.5 : 5.5,
                      color: segment.isWalk
                          ? kWalk.withValues(alpha: 0.8)
                          : kBus.withValues(alpha: 0.85),
                      pattern: segment.isWalk
                          ? StrokePattern.dashed(segments: [10, 7])
                          : const StrokePattern.solid(),
                    ),
                ],
              ),
              if (_showBusStops && _stopMarkers.isNotEmpty)
                MarkerLayer(markers: _stopMarkers),
              if (routeStopMarkers.isNotEmpty)
                MarkerLayer(markers: routeStopMarkers),
              if (_isLiveTrackingActive && _busMarkers.isNotEmpty)
                MarkerLayer(markers: _busMarkers),
              MarkerLayer(
                markers: [
                  Marker(
                    point: _currentLocation,
                    width: 42,
                    height: 42,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _hasRealLocation ? kBus : Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [
                          BoxShadow(
                            color: (_hasRealLocation ? kBus : Colors.green)
                                .withValues(alpha: 0.35),
                            blurRadius: 8,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Icon(
                        _hasRealLocation
                            ? Icons.person_pin_circle
                            : Icons.location_searching,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  if (_customStartFeature != null)
                    Marker(
                      point: LatLng(
                        _customStartFeature!['lat'],
                        _customStartFeature!['lon'],
                      ),
                      width: 42,
                      height: 42,
                      child: const _StartMarker(),
                    ),
                  if (_destinationFeature != null)
                    Marker(
                      point: LatLng(
                        _destinationFeature!['lat'],
                        _destinationFeature!['lon'],
                      ),
                      width: 42,
                      height: 52,
                      child: const _DestinationMarker(),
                    ),
                ],
              ),
            ],
          ),

          // Search panel
          Positioned(top: 12, left: 12, right: 12, child: _buildSearchPanel()),

          // Stop search overlay
          if (_showBusStops)
            Positioned(
              bottom: (_routeOptions.isNotEmpty || _isLoading) ? 270 : 80,
              left: 16,
              right: 80,
              child: _buildStopSearchOverlay(),
            ),

          // Selecting start hint
          if (_isSelectingStart)
            Positioned(
              top: _showSearchPanel ? 210 : 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: kWalk,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: kWalk.withValues(alpha: 0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.touch_app, color: Colors.white, size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Napauta kartalta lähtöpiste',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Route sheet
          if (_routeOptions.isNotEmpty || _isLoading) _buildRouteSheet(),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 40.0),
        child: FloatingActionButton.extended(
          onPressed: _toggleLiveTracking,
          backgroundColor: _isLiveTrackingActive ? kDelayed : kLiveBus,
          foregroundColor: _isLiveTrackingActive ? Colors.white : kPrimaryDark,
          elevation: 4,
          icon: Icon(
            _isLiveTrackingActive ? Icons.stop_circle : Icons.satellite_alt,
          ),
          label: Text(_isLiveTrackingActive ? 'Lopeta Live' : 'Aloita Live'),
        ),
      ),
    );
  }
}

// ─── Data models ──────────────────────────────────────────────────────────────
class AlertInfo {
  final String text;
  AlertInfo({required this.text});
}

class IntermediateStop {
  final String name;
  final double lat;
  final double lon;

  IntermediateStop({required this.name, required this.lat, required this.lon});

  Map<String, dynamic> toJson() => {'name': name, 'lat': lat, 'lon': lon};

  factory IntermediateStop.fromJson(Map<String, dynamic> json) =>
      IntermediateStop(
        name: json['name'] ?? '',
        lat: (json['lat'] as num).toDouble(),
        lon: (json['lon'] as num).toDouble(),
      );
}

class StopTimeData {
  final int scheduledEpochSec;
  final int realtimeEpochSec;
  final String realtimeState;
  final bool isRealtime;
  final String? busNumber;
  final String? headsign;

  StopTimeData({
    required this.scheduledEpochSec,
    required this.realtimeEpochSec,
    required this.realtimeState,
    required this.isRealtime,
    this.busNumber,
    this.headsign,
  });
}

class BusLeg {
  final String busNumber;
  final String routeGtfsId;
  final String fromStop;
  final String fromStopId;
  final double? fromLat;
  final double? fromLon;
  final String toStop;
  final double? toLat;
  final double? toLon;
  final DateTime departureTime;
  final DateTime arrivalTime;
  final DateTime realtimeDeparture;
  final String realtimeState;
  final bool isRealtime;
  final List<IntermediateStop> intermediateStops;
  final List<AlertInfo> alerts;

  BusLeg({
    required this.busNumber,
    this.routeGtfsId = '',
    required this.fromStop,
    required this.fromStopId,
    this.fromLat,
    this.fromLon,
    required this.toStop,
    this.toLat,
    this.toLon,
    required this.departureTime,
    required this.arrivalTime,
    required this.realtimeDeparture,
    required this.realtimeState,
    required this.isRealtime,
    this.intermediateStops = const [],
    this.alerts = const [],
  });

  Map<String, dynamic> toJson() => {
    'busNumber': busNumber,
    'routeGtfsId': routeGtfsId,
    'fromStop': fromStop,
    'fromStopId': fromStopId,
    'fromLat': fromLat,
    'fromLon': fromLon,
    'toStop': toStop,
    'toLat': toLat,
    'toLon': toLon,
    'departureTime': departureTime.millisecondsSinceEpoch,
    'arrivalTime': arrivalTime.millisecondsSinceEpoch,
    'realtimeDeparture': realtimeDeparture.millisecondsSinceEpoch,
    'realtimeState': realtimeState,
    'isRealtime': isRealtime,
    'intermediateStops': intermediateStops.map((s) => s.toJson()).toList(),
    'alerts': alerts.map((a) => a.text).toList(),
  };

  factory BusLeg.fromJson(Map<String, dynamic> json) => BusLeg(
    busNumber: json['busNumber'] ?? '',
    routeGtfsId: json['routeGtfsId'] ?? '',
    fromStop: json['fromStop'] ?? '',
    fromStopId: json['fromStopId'] ?? '',
    fromLat: (json['fromLat'] as num?)?.toDouble(),
    fromLon: (json['fromLon'] as num?)?.toDouble(),
    toStop: json['toStop'] ?? '',
    toLat: (json['toLat'] as num?)?.toDouble(),
    toLon: (json['toLon'] as num?)?.toDouble(),
    departureTime: DateTime.fromMillisecondsSinceEpoch(
      json['departureTime'] ?? 0,
    ),
    arrivalTime: DateTime.fromMillisecondsSinceEpoch(json['arrivalTime'] ?? 0),
    realtimeDeparture: DateTime.fromMillisecondsSinceEpoch(
      json['realtimeDeparture'] ?? 0,
    ),
    realtimeState: json['realtimeState'] ?? 'SCHEDULED',
    isRealtime: json['isRealtime'] ?? false,
    intermediateStops: (json['intermediateStops'] as List? ?? [])
        .map((s) => IntermediateStop.fromJson(s as Map<String, dynamic>))
        .toList(),
    alerts: (json['alerts'] as List? ?? [])
        .map((a) => AlertInfo(text: a.toString()))
        .toList(),
  );
}

class RouteSegment {
  final List<LatLng> points;
  final bool isWalk;

  RouteSegment({required this.points, required this.isWalk});
}

class RouteOption {
  final DateTime leaveHomeTime;
  final DateTime arrivalTime;
  final List<BusLeg> busLegs;
  final List<RouteSegment> segments;
  final List<double> walkDistances;

  RouteOption({
    required this.leaveHomeTime,
    required this.arrivalTime,
    required this.busLegs,
    required this.segments,
    this.walkDistances = const [],
  });

  Map<String, dynamic> toJson() => {
    'leaveHomeTime': leaveHomeTime.millisecondsSinceEpoch,
    'arrivalTime': arrivalTime.millisecondsSinceEpoch,
    'walkDistances': walkDistances,
    'busLegs': busLegs.map((l) => l.toJson()).toList(),
    // segments are omitted – cannot be shown on map when offline
  };

  factory RouteOption.fromJson(Map<String, dynamic> json) => RouteOption(
    leaveHomeTime: DateTime.fromMillisecondsSinceEpoch(
      json['leaveHomeTime'] ?? 0,
    ),
    arrivalTime: DateTime.fromMillisecondsSinceEpoch(json['arrivalTime'] ?? 0),
    walkDistances: List<double>.from(
      (json['walkDistances'] as List? ?? []).map((v) => (v as num).toDouble()),
    ),
    busLegs: (json['busLegs'] as List? ?? [])
        .map((l) => BusLeg.fromJson(l as Map<String, dynamic>))
        .toList(),
    segments: [], // empty when loaded from offline cache
  );
}
