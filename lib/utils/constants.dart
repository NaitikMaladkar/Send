/// Send — public Supabase config.
///
/// These values are intentionally committed to the repo. The anon key is
/// designed to be embedded in client apps — Row Level Security on every
/// table ensures it cannot read or write data without a valid per-identity
/// auth token issued by `register_identity()`.
class SupabaseConfig {
  static const String url = 'https://xtpsvneqdsaiqtqxakhu.supabase.co';
  static const String anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inh0'
      'cHN2bmVxZHNhaXF0cXhha2h1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM4NTkwOTMsImV4'
      'cCI6MjA5OTQzNTA5M30.7SqykFJu3YM7ofibeOj2U21fOvMV-LpB1IDBAz6jsDg';

  static const String storageBucket = 'attachments';
  static const int imageMaxBytes = 10 * 1024 * 1024; // 10 MB
  static const int pdfMaxBytes = 25 * 1024 * 1024;   // 25 MB
}

/// Inactivity window before server-side cron deletes the identity.
class InactivityConfig {
  static const Duration warnAfter = Duration(days: 25);
  static const Duration deleteAfter = Duration(days: 30);
}
