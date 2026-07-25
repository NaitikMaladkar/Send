# Send — Privacy Policy

**Last updated:** 2026-07-14

Send is an anonymous, end-to-end encrypted chat application. This policy
describes what data the app and its backend store, how long it is kept, and
what is *not* collected.

## What we collect

### On your device (never uploaded)

- **Your private key** — 32-byte X25519 seed, stored in Android Keystore via
  `flutter_secure_storage`. Used to derive shared symmetric keys with each
  peer.
- **Cached friend public keys** — the public half of each peer's keypair,
  cached locally to avoid re-fetching.
- **Cached shared keys** — per-peer HKDF-derived 32-byte symmetric keys,
  cached locally to avoid recomputing ECDH on every message.
- **Active identity id + auth token** — the random 32-byte hex token issued
  by `register_identity()`. Required to authenticate server RPCs.

### On the server (Supabase Postgres)

- **Your identity row** — `id`, `public_key` (32 bytes), `auth_token` (64-char
  hex), `display_code` (7-digit number, informational), `last_active_at`,
  `created_at`.
- **Rotating codes you generate** — `code`, your `identity_id`, optional
  `alias`, `expires_at`, `used_at`. Auto-deleted 24 hours after creation.
- **Friend requests you send or receive** — `from_identity`, `to_identity`,
  `intro` (optional, user-provided), `status`, timestamps.
- **Messages** — `from_identity`, `to_identity`, `ciphertext` (binary),
  `iv` (12 bytes), `kind`, optional `attachment_path`, delivery/read
  timestamps. **Plaintext is never stored.** Ciphertext can only be
  decrypted with the per-peer shared key, which is never uploaded.
- **Attachments** — encrypted blobs in a private Supabase Storage bucket.
  Format: `iv ‖ ciphertext`. Decryption requires the per-peer shared key.

### What we DO NOT collect

- ❌ Phone numbers, email addresses, names, or any PII
- ❌ Device identifiers (IMEI, Android ID, advertising ID)
- ❌ Location data
- ❌ Contacts list
- ❌ Analytics, crash reports, or telemetry
- ❌ IP addresses (Supabase logs may transiently retain them for security
  purposes; we do not query, aggregate, or store them in app data)

## How data is used

- To deliver your messages and friend requests to the intended recipient.
- To authenticate your RPC calls via the `X-Identity-Id` +
  `X-Identity-Token` headers.
- To enforce the 30-day inactivity auto-delete.

That's it. We never use your data for advertising, profiling, or training.

## How long data is kept

| Data | Retention |
|---|---|
| Identity row | Until 30 days of inactivity, then deleted by daily cron |
| Rotating codes | 24 hours, or until first use |
| Friend requests | Until responded or identity deleted |
| Messages | Until identity deleted (cleanup cascade) |
| Attachments | Until identity deleted (paths become unreachable) |

**There is no recovery.** If your identity is deleted — manually by you, or
automatically after 30 days of inactivity — your messages are gone forever.
There is no backup, no archive, no audit log of plaintext.

## Data sharing

We do not share your data with any third party, except:

- **Supabase** (the backend infrastructure provider) — they host the
  Postgres database and Storage bucket. They cannot read your messages
  because all stored data is encrypted before upload.
- **As required by law** — if served a valid legal request, we can only
  provide the encrypted ciphertext blobs (which are useless without the
  per-peer shared keys, which exist only on the devices of the
  participants).

## Your choices

- **Delete your identity** — Profile → Delete active identity. Wipes your
  local keypair and triggers server-side cleanup within 24 hours.
- **Switch identities** — Profile → Create another identity. You can
  maintain multiple anonymous identities on one device.
- **Generate a new rotating code** — Add Friend → Generate code. Old codes
  remain valid until expiry or use.
- **Uninstall the app** — removes all local data. Server-side data is
  retained until the 30-day inactivity timeout.

## Children

Send is not directed at children under 13. We do not knowingly collect data
from children. If you believe a child has registered an identity, contact us
and we will delete it.

## Changes

We may update this policy from time to time. Material changes will be
announced in the app's release notes on GitHub.

## Contact

Open an issue at [github.com/NaitikMaladkar/Send/issues](https://github.com/NaitikMaladkar/Send/issues).
