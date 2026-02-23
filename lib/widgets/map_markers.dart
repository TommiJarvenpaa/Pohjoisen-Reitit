import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../theme/app_colors.dart';

class StartMarker extends StatelessWidget {
  const StartMarker({super.key});
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

class DestinationMarker extends StatelessWidget {
  const DestinationMarker({super.key});
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

class BoardingStopMarker extends StatelessWidget {
  final String name;
  const BoardingStopMarker(this.name, {super.key});
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

class AlightingStopMarker extends StatelessWidget {
  final String name;
  const AlightingStopMarker(this.name, {super.key});
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

class StopDot extends StatelessWidget {
  final String name;
  const StopDot(this.name, {super.key});
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

class IntermediateStopDot extends StatelessWidget {
  final String name;
  const IntermediateStopDot(this.name, {super.key});
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

class LiveBusMarker extends StatelessWidget {
  final String busNumber;
  final double bearing;

  const LiveBusMarker(this.busNumber, {super.key, this.bearing = 0.0});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: Stack(
        clipBehavior: Clip.none, // Sallii nuolen piirtyä laatikon ulkopuolelle
        alignment: Alignment.center,
        children: [
          // 1. Pyörivä suuntanuoli pallon ulkokehällä
          Transform.rotate(
            angle: bearing * (math.pi / 180),
            child: Transform.translate(
              offset: const Offset(0, -21),
              child: const Icon(Icons.navigation, color: Colors.red, size: 14),
            ),
          ),
          // 2. Bussipallero, jonka SISÄLLÄ on nyt vuoronumero
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
            child: Center(
              child: Text(
                busNumber,
                style: const TextStyle(
                  color: kPrimaryDark,
                  fontWeight: FontWeight.bold,
                  fontSize: 12, // Sopiva koko, jotta numerot mahtuvat palloon
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
