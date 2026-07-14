import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'services/auth_service.dart';
import 'services/chat_service.dart';
import 'services/notification_service.dart';
import 'services/screenshot_service.dart';
import 'screens/splash_screen.dart';
import 'utils/constants.dart';
import 'utils/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.anonKey,
    debug: false,
    realtimeClientOptions: const RealtimeClientOptions(
      eventsPerSecond: 10,
    ),
  );

  await NotificationService.init();
  await NotificationService.initForegroundTask();

  // Enable FLAG_SECURE app-wide so screenshots are blocked (Android).
  // This implements the "self-destruct on screenshot" feature by
  // preventing screenshots in the first place.
  await ScreenshotService.enableSecure();

  final themeService = ThemeService();
  await themeService.init();

  runApp(SendApp(themeService: themeService));
}

class SendApp extends StatelessWidget {
  final ThemeService themeService;
  const SendApp({super.key, required this.themeService});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        Provider<ChatService>(create: (ctx) => ChatService(ctx.read<AuthService>())),
        ChangeNotifierProvider.value(value: themeService),
      ],
      child: Consumer<ThemeService>(
        builder: (context, ts, _) => MaterialApp(
          title: 'Send',
          debugShowCheckedModeBanner: false,
          theme: SendTheme.light(),
          darkTheme: SendTheme.dark(),
          themeMode: ts.flutterMode,
          home: const SplashScreen(),
        ),
      ),
    );
  }
}
