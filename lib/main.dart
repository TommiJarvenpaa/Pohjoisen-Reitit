import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart'; // Lisätty SystemChromea varten
import 'theme/app_colors.dart';
import 'screens/map_screen.dart'; // Tämän luomme seuraavassa viestissä

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  // Asetetaan Androidin navigaatiopalkki valkoiseksi ja sen ikonit tummiksi
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  // Riverpod vaatii ProviderScope-käärimisen juureen
  runApp(const ProviderScope(child: PohjoisenReitit()));
}

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
