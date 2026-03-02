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
class MinTransferTimeNotifier extends StateNotifier<int> {
  MinTransferTimeNotifier() : super(120) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt('min_transfer_time');
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> set(int value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('min_transfer_time', value);
  }
}

final minTransferTimeProvider =
    StateNotifierProvider<MinTransferTimeNotifier, int>((ref) {
      return MinTransferTimeNotifier();
    });

class WalkSpeedNotifier extends StateNotifier<double> {
  WalkSpeedNotifier() : super(5.0) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble('walk_speed_kmh');
    if (saved != null) {
      state = saved;
    }
  }

  Future<void> set(double value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('walk_speed_kmh', value);
  }
}

final walkSpeedProvider = StateNotifierProvider<WalkSpeedNotifier, double>((
  ref,
) {
  return WalkSpeedNotifier();
});

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
    try {
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
    } catch (_) {
      // Old or corrupt cache format
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
  final FeedMessage? tripUpdateFeed;
  final bool isActive;
  final bool isFetching;

  LiveBusState({
    this.feed,
    this.tripUpdateFeed,
    this.isActive = false,
    this.isFetching = false,
  });

  LiveBusState copyWith({
    FeedMessage? feed,
    FeedMessage? tripUpdateFeed,
    bool? isActive,
    bool? isFetching,
  }) => LiveBusState(
    feed: feed ?? this.feed,
    tripUpdateFeed: tripUpdateFeed ?? this.tripUpdateFeed,
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
  Timer? _positionTimer;
  Timer? _tripUpdateTimer;
  bool _isFetchingTripUpdates = false;

  LiveBusNotifier(this._api) : super(LiveBusState());

  void toggleTracking() {
    if (state.isActive) {
      _positionTimer?.cancel();
      _tripUpdateTimer?.cancel();
      state = LiveBusState(isActive: false, feed: null, tripUpdateFeed: null);
    } else {
      state = state.copyWith(isActive: true);

      // Haetaan heti kun laitetaan päälle
      fetchBuses();
      fetchTripUpdates();

      // Sijainnit 3 sekunnin välein
      _positionTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        fetchBuses();
      });

      // Pysäkkien viiveet 30 sekunnin välein
      _tripUpdateTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        fetchTripUpdates();
      });
    }
  }

  Future<void> fetchBuses() async {
    if (state.isFetching) return;
    state = state.copyWith(isFetching: true);
    final feed = await _api.fetchLiveBuses();
    if (state.isActive) state = state.copyWith(feed: feed, isFetching: false);
  }

  Future<void> fetchTripUpdates() async {
    if (_isFetchingTripUpdates) return;
    _isFetchingTripUpdates = true;
    try {
      final tripFeed = await _api.fetchTripUpdates();
      if (state.isActive) {
        state = state.copyWith(tripUpdateFeed: tripFeed);
      }
    } finally {
      _isFetchingTripUpdates = false;
    }
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _tripUpdateTimer?.cancel();
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
