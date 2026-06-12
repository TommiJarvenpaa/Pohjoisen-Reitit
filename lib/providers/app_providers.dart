import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_models.dart';
import '../services/transit_service.dart';

// Service provider
final transitServiceProvider = Provider((ref) {
  final service = TransitService(
    digitransitKey: dotenv.env['DIGITRANSIT_KEY'] ?? '',
    walttiClientId: dotenv.env['WALTTI_CLIENT_ID'] ?? '',
    walttiClientSecret: dotenv.env['WALTTI_CLIENT_SECRET'] ?? '',
  );
  ref.onDispose(service.dispose);
  return service;
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

// Historia – säilyy uudelleenkäynnistysten yli kuten suosikit ja asetukset.
class RecentSearchesNotifier extends StateNotifier<List<Place>> {
  RecentSearchesNotifier() : super(const []) {
    _load();
  }

  static const String _prefsKey = 'recent_searches';
  static const int _maxEntries = 5;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey) ?? [];
      state = raw
          .map((s) => Place.fromJson(json.decode(s) as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Failed to load recent searches: $e');
    }
  }

  Future<void> add(Place place) async {
    state = [
      place,
      ...state.where((o) => o.name != place.name),
    ].take(_maxEntries).toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefsKey,
        state.map((p) => json.encode(p.toJson())).toList(),
      );
    } catch (e) {
      debugPrint('Failed to save recent searches: $e');
    }
  }
}

final recentSearchesProvider =
    StateNotifierProvider<RecentSearchesNotifier, List<Place>>((ref) {
      return RecentSearchesNotifier();
    });

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

  /// Käyttäjälle näytettävä virheilmoitus. Erottaa "ei reittejä löytynyt"
  /// -tilanteen verkkovirheestä.
  final String? errorMessage;

  RouteState({
    this.options = const [],
    this.isLoading = false,
    this.isOffline = false,
    this.selectedIndex = 0,
    this.errorMessage,
  });

  RouteState copyWith({
    List<RouteOption>? options,
    bool? isLoading,
    bool? isOffline,
    int? selectedIndex,
    String? errorMessage,
    bool clearError = false,
  }) {
    return RouteState(
      options: options ?? this.options,
      isLoading: isLoading ?? this.isLoading,
      isOffline: isOffline ?? this.isOffline,
      selectedIndex: selectedIndex ?? this.selectedIndex,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
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
    state = state.copyWith(isLoading: true, isOffline: false, clearError: true);
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
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        options: options,
        selectedIndex: 0,
      );
      if (options.isNotEmpty && destPlace != null) {
        _saveOfflineCache(options, destPlace);
      }
    } on TimeoutException {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        errorMessage:
            'Reittihaku aikakatkaistiin. Tarkista verkkoyhteys ja yritä uudelleen.',
      );
    } catch (e) {
      debugPrint('Route search failed: $e');
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        errorMessage:
            'Reittihaku epäonnistui. Tarkista verkkoyhteys ja yritä uudelleen.',
      );
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
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'last_route_options',
        json.encode(options.map((r) => r.toJson()).toList()),
      );
      await prefs.setString('last_dest_name', dest.name);
      await prefs.setDouble('last_dest_lat', dest.lat);
      await prefs.setDouble('last_dest_lon', dest.lon);
    } catch (e) {
      debugPrint('Failed to save offline cache: $e');
    }
  }
}

// Live seuranta
class LiveBusState {
  /// Bussien sijainnit Waltti GTFS-RT-feedistä (vain karttamerkit).
  final FeedMessage? feed;

  /// Vuorojen pysäkkikohtaiset viiveet reititys-API:sta, avaimena
  /// vuoron gtfsId.
  final Map<String, TripRealtime>? tripRealtime;
  final bool isActive;
  final bool isFetching;

  /// Viimeisimmän ONNISTUNEEN haun ajankohta. Epäonnistunut haku ei
  /// päivitä leimaa, jolloin UI osaa kohdella dataa vanhentuneena.
  final DateTime? positionsUpdatedAt;
  final DateTime? tripUpdatesUpdatedAt;

  // Sijainnit haetaan 3 s välein, viiveet 30 s välein. Raja on reilusti
  // hakuväliä suurempi, jotta yksittäinen epäonnistuminen ei vilkuta UI:ta.
  static const Duration _positionsMaxAge = Duration(seconds: 30);
  static const Duration _tripUpdatesMaxAge = Duration(seconds: 90);

  LiveBusState({
    this.feed,
    this.tripRealtime,
    this.isActive = false,
    this.isFetching = false,
    this.positionsUpdatedAt,
    this.tripUpdatesUpdatedAt,
  });

  /// Onko bussien sijaintidata tarpeeksi tuoretta näytettäväksi kartalla.
  bool get hasFreshPositions =>
      feed != null &&
      positionsUpdatedAt != null &&
      DateTime.now().difference(positionsUpdatedAt!) < _positionsMaxAge;

  /// Onko pysäkkiviivedata tarpeeksi tuoretta Live-merkin näyttämiseen.
  bool get hasFreshTripUpdates =>
      tripRealtime != null &&
      tripUpdatesUpdatedAt != null &&
      DateTime.now().difference(tripUpdatesUpdatedAt!) < _tripUpdatesMaxAge;

  LiveBusState copyWith({
    FeedMessage? feed,
    Map<String, TripRealtime>? tripRealtime,
    bool? isActive,
    bool? isFetching,
    DateTime? positionsUpdatedAt,
    DateTime? tripUpdatesUpdatedAt,
  }) => LiveBusState(
    feed: feed ?? this.feed,
    tripRealtime: tripRealtime ?? this.tripRealtime,
    isActive: isActive ?? this.isActive,
    isFetching: isFetching ?? this.isFetching,
    positionsUpdatedAt: positionsUpdatedAt ?? this.positionsUpdatedAt,
    tripUpdatesUpdatedAt: tripUpdatesUpdatedAt ?? this.tripUpdatesUpdatedAt,
  );
}

final liveBusProvider = StateNotifierProvider<LiveBusNotifier, LiveBusState>((
  ref,
) {
  return LiveBusNotifier(ref.read(transitServiceProvider), ref);
});

class LiveBusNotifier extends StateNotifier<LiveBusState> {
  final TransitService _api;
  final Ref _ref;
  Timer? _positionTimer;
  Timer? _tripUpdateTimer;
  bool _isFetchingTripUpdates = false;

  LiveBusNotifier(this._api, this._ref) : super(LiveBusState());

  void toggleTracking() {
    if (state.isActive) {
      _positionTimer?.cancel();
      _tripUpdateTimer?.cancel();
      state = LiveBusState(isActive: false, feed: null, tripRealtime: null);
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
    // Service käsittelee virheet ja palauttaa null epäonnistuessa.
    final feed = await _api.fetchLiveBuses();
    if (!mounted || !state.isActive) return;
    if (feed != null) {
      state = state.copyWith(
        feed: feed,
        positionsUpdatedAt: DateTime.now(),
        isFetching: false,
      );
    } else {
      // Vanha feed jää talteen, mutta aikaleima ei päivity – UI piilottaa
      // vanhentuneet sijainnit hasFreshPositions-tarkistuksella.
      state = state.copyWith(isFetching: false);
    }
  }

  /// Näkyvien reittiehdotusten vuorot, valitun vaihtoehdon vuorot ensin –
  /// jos vuoroja on enemmän kuin kyselyyn mahtuu, tärkeimmät säilyvät.
  List<String> _visibleTripIds() {
    final routeState = _ref.read(routeStateProvider);
    final List<String> ids = [];
    void addOption(RouteOption opt) {
      for (final leg in opt.busLegs) {
        if (leg.tripId.isNotEmpty && !ids.contains(leg.tripId)) {
          ids.add(leg.tripId);
        }
      }
    }

    final options = routeState.options;
    if (options.isNotEmpty) {
      final selected = routeState.selectedIndex.clamp(0, options.length - 1);
      addOption(options[selected]);
      for (final opt in options) {
        addOption(opt);
      }
    }
    return ids;
  }

  Future<void> fetchTripUpdates() async {
    if (_isFetchingTripUpdates) return;
    _isFetchingTripUpdates = true;
    try {
      final tripRealtime = await _api.fetchTripRealtime(_visibleTripIds());
      if (!mounted || !state.isActive) return;
      if (tripRealtime != null) {
        state = state.copyWith(
          tripRealtime: tripRealtime,
          tripUpdatesUpdatedAt: DateTime.now(),
        );
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
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('favorites') ?? [];
      state = raw.map((s) => FavoriteRoute.fromJson(json.decode(s))).toList();
    } catch (e) {
      debugPrint('Failed to load favorites: $e');
    }
  }

  bool isFavorite(Place dest) => state.any((f) => f.isSameDestination(dest));

  Future<void> toggleFavorite(Place dest, Place? start) async {
    if (isFavorite(dest)) {
      state = state.where((f) => !f.isSameDestination(dest)).toList();
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
    await _persist();
  }

  Future<void> removeFavorite(int index) async {
    final list = [...state]..removeAt(index);
    state = list;
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'favorites',
        state.map((f) => json.encode(f.toJson())).toList(),
      );
    } catch (e) {
      debugPrint('Failed to save favorites: $e');
    }
  }
}
