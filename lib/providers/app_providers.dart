import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_models.dart';
import '../services/transit_service.dart';

// Service provider
final transitServiceProvider = Provider((ref) {
  return TransitService(
    digitransitKey: dotenv.env['DIGITRANSIT_KEY'] ?? '',
    walttiClientId: dotenv.env['WALTTI_CLIENT_ID'] ?? '',
    walttiClientSecret: dotenv.env['WALTTI_CLIENT_SECRET'] ?? '',
  );
});

// Asetukset
final minTransferTimeProvider = StateProvider<int>((ref) => 120);
final walkSpeedProvider = StateProvider<double>((ref) => 5.0);

// Historia
final recentSearchesProvider = StateProvider<List<Place>>((ref) => []);

// Sijainnit ja haun tila
final startLocationProvider = StateProvider<Place?>((ref) => null);
final destinationLocationProvider = StateProvider<Place?>((ref) => null);
final departureTimeProvider = StateProvider<DateTime>((ref) => DateTime.now());

// Reittien tila
class RouteState {
  final List<RouteOption> options;
  final bool isLoading;
  final bool isOffline;
  final int selectedIndex;

  RouteState({
    this.options = const [],
    this.isLoading = false,
    this.isOffline = false,
    this.selectedIndex = 0,
  });

  RouteState copyWith({
    List<RouteOption>? options,
    bool? isLoading,
    bool? isOffline,
    int? selectedIndex,
  }) {
    return RouteState(
      options: options ?? this.options,
      isLoading: isLoading ?? this.isLoading,
      isOffline: isOffline ?? this.isOffline,
      selectedIndex: selectedIndex ?? this.selectedIndex,
    );
  }
}

final routeStateProvider = StateNotifierProvider<RouteNotifier, RouteState>((
  ref,
) {
  return RouteNotifier(ref.read(transitServiceProvider));
});

class RouteNotifier extends StateNotifier<RouteState> {
  final TransitService _api;
  RouteNotifier(this._api) : super(RouteState()) {
    _loadOfflineCache();
  }

  void selectRoute(int index) => state = state.copyWith(selectedIndex: index);

  Future<void> searchRoute(
    double startLat,
    double startLon,
    double destLat,
    double destLon,
    DateTime time,
    int transferTime,
    double speedKmH, {
    Place? destPlace,
  }) async {
    state = state.copyWith(isLoading: true, isOffline: false);
    try {
      final double walkSpeedMS = speedKmH / 3.6;
      final options = await _api.fetchRoutes(
        startLat,
        startLon,
        destLat,
        destLon,
        time,
        transferTime,
        walkSpeedMS,
      );
      state = state.copyWith(
        isLoading: false,
        options: options,
        selectedIndex: 0,
      );
      if (options.isNotEmpty && destPlace != null) {
        _saveOfflineCache(options, destPlace);
      }
    } catch (e) {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> _loadOfflineCache() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedJson = prefs.getString('last_route_options');
    if (cachedJson != null) {
      final rawList = json.decode(cachedJson) as List<dynamic>;
      final options = rawList
          .map((item) => RouteOption.fromJson(item as Map<String, dynamic>))
          .toList();
      if (options.isNotEmpty) {
        state = state.copyWith(options: options, isOffline: true);
      }
    }
  }

  Future<void> _saveOfflineCache(List<RouteOption> options, Place dest) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'last_route_options',
      json.encode(options.map((r) => r.toJson()).toList()),
    );
    await prefs.setString('last_dest_name', dest.name);
    await prefs.setDouble('last_dest_lat', dest.lat);
    await prefs.setDouble('last_dest_lon', dest.lon);
  }
}

// Live seuranta
class LiveBusState {
  final FeedMessage? feed;
  final bool isActive;
  final bool isFetching;
  LiveBusState({this.feed, this.isActive = false, this.isFetching = false});
  LiveBusState copyWith({
    FeedMessage? feed,
    bool? isActive,
    bool? isFetching,
  }) => LiveBusState(
    feed: feed ?? this.feed,
    isActive: isActive ?? this.isActive,
    isFetching: isFetching ?? this.isFetching,
  );
}

final liveBusProvider = StateNotifierProvider<LiveBusNotifier, LiveBusState>((
  ref,
) {
  return LiveBusNotifier(ref.read(transitServiceProvider));
});

class LiveBusNotifier extends StateNotifier<LiveBusState> {
  final TransitService _api;
  Timer? _timer;

  LiveBusNotifier(this._api) : super(LiveBusState());

  void toggleTracking() {
    if (state.isActive) {
      _timer?.cancel();
      state = LiveBusState(isActive: false, feed: null);
    } else {
      state = state.copyWith(isActive: true);
      fetchBuses();
      _timer = Timer.periodic(const Duration(seconds: 15), (_) => fetchBuses());
    }
  }

  Future<void> fetchBuses() async {
    if (state.isFetching) return;
    state = state.copyWith(isFetching: true);
    final feed = await _api.fetchLiveBuses();
    if (state.isActive) state = state.copyWith(feed: feed, isFetching: false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// Suosikit
final favoritesProvider =
    StateNotifierProvider<FavoritesNotifier, List<FavoriteRoute>>((ref) {
      return FavoritesNotifier();
    });

class FavoritesNotifier extends StateNotifier<List<FavoriteRoute>> {
  FavoritesNotifier() : super([]) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('favorites') ?? [];
    state = raw.map((s) => FavoriteRoute.fromJson(json.decode(s))).toList();
  }

  Future<void> toggleFavorite(Place dest, Place? start) async {
    final alreadySaved = state.any((f) => f.destinationName == dest.name);
    if (alreadySaved) {
      state = state.where((f) => f.destinationName != dest.name).toList();
    } else {
      state = [
        FavoriteRoute(
          destinationName: dest.name,
          destLat: dest.lat,
          destLon: dest.lon,
          startName: start?.name,
          startLat: start?.lat,
          startLon: start?.lon,
          savedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
        ...state,
      ];
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'favorites',
      state.map((f) => json.encode(f.toJson())).toList(),
    );
  }

  void removeFavorite(int index) {
    var list = [...state];
    list.removeAt(index);
    state = list;
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setStringList(
        'favorites',
        state.map((f) => json.encode(f.toJson())).toList(),
      ),
    );
  }
}
