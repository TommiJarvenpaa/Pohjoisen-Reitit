import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_models.dart';
import '../services/realtime_utils.dart';
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
  /// Valmistuu, kun tallennettu arvo on luettu – haun ei pidä käyttää
  /// oletusarvoa ennen sitä.
  late final Future<void> loaded;

  MinTransferTimeNotifier() : super(120) {
    loaded = _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt('min_transfer_time');
      if (saved != null) {
        state = saved;
      }
    } catch (e) {
      debugPrint('Failed to load min transfer time: $e');
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
  /// Valmistuu, kun tallennettu arvo on luettu, ks. [MinTransferTimeNotifier].
  late final Future<void> loaded;

  WalkSpeedNotifier() : super(5.0) {
    loaded = _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble('walk_speed_kmh');
      if (saved != null) {
        state = saved;
      }
    } catch (e) {
      debugPrint('Failed to load walk speed: $e');
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
/// Käyttäjän valitsema lähtöaika. Null = "nyt", joka luetaan vasta haun
/// hetkellä – muuten aika jäätyisi sovelluksen käynnistyshetkeen.
final departureTimeProvider = StateProvider<DateTime?>((ref) => null);

/// Viimeisimmän onnistuneen haun lähtö- ja määränpää. Tallennetaan
/// reittien kanssa, jotta välimuistista ladattu reitti voidaan päivittää
/// sovelluksen käynnistyessä.
class SavedSearch {
  final Place destination;

  /// Null = lähtöpisteenä oli GPS-sijainti.
  final Place? start;

  /// Haussa käytetty lähtökoordinaatti (myös GPS-lähdössä). Puuttuu
  /// vanhasta välimuistista.
  final double? startLat;
  final double? startLon;

  /// Käyttäjän valitsema lähtöaika. Null = haettiin hetkellä "nyt".
  final DateTime? departureTime;

  SavedSearch({
    required this.destination,
    this.start,
    this.startLat,
    this.startLon,
    this.departureTime,
  });
}

// Reittien tila
class RouteState {
  final List<RouteOption> options;
  final bool isLoading;
  final bool isOffline;
  final int selectedIndex;

  /// Välimuistin reittiä päivitetään taustalla. Vanhat reitit pysyvät
  /// näkyvissä, kunnes uudet on saatu.
  final bool isRefreshing;

  /// Käyttäjälle näytettävä virheilmoitus. Erottaa "ei reittejä löytynyt"
  /// -tilanteen verkkovirheestä.
  final String? errorMessage;

  RouteState({
    this.options = const [],
    this.isLoading = false,
    this.isOffline = false,
    this.selectedIndex = 0,
    this.isRefreshing = false,
    this.errorMessage,
  });

  RouteState copyWith({
    List<RouteOption>? options,
    bool? isLoading,
    bool? isOffline,
    int? selectedIndex,
    bool? isRefreshing,
    String? errorMessage,
    bool clearError = false,
  }) {
    return RouteState(
      options: options ?? this.options,
      isLoading: isLoading ?? this.isLoading,
      isOffline: isOffline ?? this.isOffline,
      selectedIndex: selectedIndex ?? this.selectedIndex,
      isRefreshing: isRefreshing ?? this.isRefreshing,
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
  late final Future<void> _cacheLoaded;
  SavedSearch? _savedSearch;

  /// Kasvaa jokaisella haulla. Vanhentuneen haun tulos ei saa ylikirjoittaa
  /// uudemman tulosta (esim. taustapäivitys valmistuu vasta käyttäjän oman
  /// haun jälkeen).
  int _searchGeneration = 0;

  RouteNotifier(this._api) : super(RouteState()) {
    _cacheLoaded = _loadOfflineCache();
  }

  void selectRoute(int index) => state = state.copyWith(selectedIndex: index);

  /// Välimuistista ladatun reitin haku, jos ruudulla on yhä välimuistin
  /// reitti. Odottaa välimuistin latauksen.
  Future<SavedSearch?> savedSearch() async {
    await _cacheLoaded;
    return state.isOffline ? _savedSearch : null;
  }

  /// [isBackgroundRefresh]: välimuistin reitin päivitys. Vanhat reitit
  /// pysyvät näkyvissä haun ajan, eikä epäonnistumisesta näytetä virhettä
  /// (verkkoyhteyttä ei ehkä ole) – reitit jäävät offline-tilaan.
  /// [chosenTime]: käyttäjän valitsema lähtöaika (null = "nyt"), joka
  /// tallennetaan välimuistiin päivitystä varten.
  Future<void> searchRoute(
    double startLat,
    double startLon,
    double destLat,
    double destLon,
    DateTime time,
    int transferTime,
    double speedKmH, {
    Place? destPlace,
    Place? startPlace,
    DateTime? chosenTime,
    bool isBackgroundRefresh = false,
  }) async {
    final int generation = ++_searchGeneration;
    // Offline-merkintä poistuu vasta onnistuneesta hausta: epäonnistunut
    // haku ei saa saada välimuistin reittejä näyttämään tuoreilta.
    state = isBackgroundRefresh
        ? state.copyWith(isRefreshing: true)
        : state.copyWith(isLoading: true, isRefreshing: false, clearError: true);
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
      if (!mounted || generation != _searchGeneration) return;
      state = state.copyWith(
        isLoading: false,
        isRefreshing: false,
        isOffline: false,
        options: options,
        selectedIndex: 0,
        clearError: true,
      );
      if (options.isNotEmpty && destPlace != null) {
        _saveOfflineCache(
          options,
          destPlace,
          startPlace,
          startLat,
          startLon,
          chosenTime,
        );
      }
    } on TimeoutException {
      if (!mounted || generation != _searchGeneration) return;
      _onSearchFailed(
        'Reittihaku aikakatkaistiin. Tarkista verkkoyhteys ja yritä uudelleen.',
        isBackgroundRefresh: isBackgroundRefresh,
      );
    } catch (e) {
      debugPrint('Route search failed: $e');
      if (!mounted || generation != _searchGeneration) return;
      _onSearchFailed(
        'Reittihaku epäonnistui. Tarkista verkkoyhteys ja yritä uudelleen.',
        isBackgroundRefresh: isBackgroundRefresh,
      );
    }
  }

  void _onSearchFailed(String message, {required bool isBackgroundRefresh}) {
    if (isBackgroundRefresh) {
      debugPrint('Cached route refresh failed, keeping offline routes');
      state = state.copyWith(isRefreshing: false, isLoading: false);
      return;
    }
    state = state.copyWith(isLoading: false, errorMessage: message);
  }

  /// Välimuistin reitti on vanha tilannekuva: hakuhetken viiveet ja
  /// tilatiedot eivät enää pidä paikkaansa, joten näytetään vain aikataulu.
  static RouteOption _withoutRealtime(RouteOption option) => option.copyWith(
    busLegs: option.busLegs
        .map(
          (leg) => leg.copyWith(
            isRealtime: false,
            realtimeDeparture: leg.departureTime,
            clearRealtimeArrival: true,
            realtimeState: 'SCHEDULED',
            intermediateStops: leg.intermediateStops
                .map((s) => s.withoutEstimate())
                .toList(),
          ),
        )
        .toList(),
  );

  Future<void> _loadOfflineCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString('last_route_options');
      if (cachedJson != null) {
        final rawList = json.decode(cachedJson) as List<dynamic>;
        final options = rawList
            .map((item) => RouteOption.fromJson(item as Map<String, dynamic>))
            .map(_withoutRealtime)
            .toList();
        // Käyttäjä ehti jo hakea – välimuisti ei saa korvata uutta tulosta.
        if (options.isNotEmpty && _searchGeneration == 0) {
          state = state.copyWith(options: options, isOffline: true);
          _savedSearch = _readSavedSearch(prefs);
        }
      }
    } catch (e) {
      // Vanha tai korruptoitunut välimuisti – jatketaan ilman sitä.
      debugPrint('Failed to load offline cache: $e');
    }
  }

  SavedSearch? _readSavedSearch(SharedPreferences prefs) {
    final String? destName = prefs.getString('last_dest_name');
    final double? destLat = prefs.getDouble('last_dest_lat');
    final double? destLon = prefs.getDouble('last_dest_lon');
    if (destName == null || destLat == null || destLon == null) return null;

    final String? startJson = prefs.getString('last_start_place');
    final int? departureMs = prefs.getInt('last_departure_time');
    return SavedSearch(
      destination: Place(name: destName, lat: destLat, lon: destLon),
      start: startJson == null
          ? null
          : Place.fromJson(json.decode(startJson) as Map<String, dynamic>),
      startLat: prefs.getDouble('last_start_lat'),
      startLon: prefs.getDouble('last_start_lon'),
      departureTime: departureMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(departureMs),
    );
  }

  Future<void> _saveOfflineCache(
    List<RouteOption> options,
    Place dest,
    Place? start,
    double startLat,
    double startLon,
    DateTime? chosenTime,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'last_route_options',
        json.encode(options.map((r) => r.toJson()).toList()),
      );
      await prefs.setString('last_dest_name', dest.name);
      await prefs.setDouble('last_dest_lat', dest.lat);
      await prefs.setDouble('last_dest_lon', dest.lon);
      if (start != null) {
        await prefs.setString('last_start_place', json.encode(start.toJson()));
      } else {
        await prefs.remove('last_start_place');
      }
      await prefs.setDouble('last_start_lat', startLat);
      await prefs.setDouble('last_start_lon', startLon);
      if (chosenTime != null) {
        await prefs.setInt(
          'last_departure_time',
          chosenTime.millisecondsSinceEpoch,
        );
      } else {
        await prefs.remove('last_departure_time');
      }
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
  /// Tyhjä tulos ei riitä: Live-merkki palaa vain, kun ainakin yhdelle
  /// näkyvälle vuorolle on oikeasti tullut reaaliaikatietoa.
  bool get hasFreshTripUpdates =>
      tripRealtime != null &&
      tripRealtime!.isNotEmpty &&
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

  /// Näkyvien reittiehdotusten vaiheet, valitun vaihtoehdon vaiheet ensin –
  /// jos vuoroja on enemmän kuin kyselyyn mahtuu, tärkeimmät säilyvät.
  /// Välimuistin reitit ovat vanhoja lähtöjä, joille ei haeta live-tietoa.
  List<BusLeg> _visibleLegs() {
    final routeState = _ref.read(routeStateProvider);
    final options = routeState.options;
    if (routeState.isOffline || options.isEmpty) return [];

    final selected = routeState.selectedIndex.clamp(0, options.length - 1);
    return [
      ...options[selected].busLegs,
      for (final opt in options) ...opt.busLegs,
    ];
  }

  Future<void> fetchTripUpdates() async {
    if (_isFetchingTripUpdates) return;
    _isFetchingTripUpdates = true;
    try {
      final tripRealtime = await _api.fetchTripRealtime(_visibleLegs());
      if (!mounted || !state.isActive) return;
      if (tripRealtime != null) {
        state = state.copyWith(
          // Ohitetulle pysäkille jää viimeisin aito ennuste eikä OTP:n
          // taaksepäin kopioima myöhempi viive.
          tripRealtime: mergeTripRealtime(state.tripRealtime, tripRealtime),
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
