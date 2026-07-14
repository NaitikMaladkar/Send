import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'services/auth_service.dart';
import 'services/chat_service.dart';
import 'services/notification_service.dart';
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

  runApp(const SendApp());
}

class SendApp extends StatelessWidget {
  const SendApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        Provider<ChatService>(create: (ctx) => ChatService(ctx.read<AuthService>())),
      ],
      child: MaterialApp(
        title: 'Send',
        debugShowCheckedModeBanner: false,
        theme: SendTheme.dark(),
        home: const SplashScreen(),
      ),
    );
  }
}
