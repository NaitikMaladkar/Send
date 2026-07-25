# Send — ProGuard rules
# Keep cryptography package internals (uses reflection on KeyPairType)
-keep class org.bouncycastle.** { *; }
-keep class com.google.crypto.tink.** { *; }

# Keep supabase flutter client
-keep class io.supabase.** { *; }
-keepclassmembers class io.supabase.** { *; }

# Keep Flutter / Dart glue
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# FlutterForegroundTask — needs its service class intact
-keep class com.flutter_foreground_task.** { *; }

# Don't warn about missing optional native libs
-dontwarn javax.annotation.**

# Missing Play Core classes (we don't ship to Play Store, so suppress)
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.app.FlutterPlayStoreSplitApplication
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
