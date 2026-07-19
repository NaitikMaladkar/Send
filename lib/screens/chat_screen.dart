import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_view/photo_view.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/friend.dart';
import '../models/message.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/haptic_service.dart';
import '../services/supabase_backend.dart';
import '../utils/constants.dart';
import '../widgets/empty_state.dart';

class ChatScreen extends StatefulWidget {
  final Friend friend;
  const ChatScreen({super.key, required this.friend});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Message> _messages = [];
  RealtimeChannel? _channel;
  RealtimeChannel? _typingChannel;
  Timer? _poll;
  Timer? _relayPoll;
  Timer? _typingDebounce;
  bool _typingDebounceActive = false;
  bool _sending = false;
  bool _peerTyping = false;
  Timer? _peerTypingTimer;
  StreamSubscription? _playerCompleteSub;
  StreamSubscription? _playerPositionSub;
  String? _currentlyPlayingId;

  // Voice recording
  final _audioRecorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();
  bool _recording = false;
  Duration _recordDuration = Duration.zero;
  Timer? _recordTimer;
  String? _recordPath;

  // Voice playback state per message
  final Map<String, bool> _playingVoice = {};
  final Map<String, Duration> _voicePosition = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setup());
    _input.addListener(_onInputChanged);
  }

  void _onInputChanged() {
    if (_input.text.isNotEmpty) {
      // Throttle: only send typing=true every 2 seconds while user is typing
      if (!_typingDebounceActive) {
        _typingDebounceActive = true;
        SupabaseBackend.broadcastTyping(
          myId: context.read<AuthService>().active!.id,
          peerId: widget.friend.identityId,
          typing: true,
        );
        _typingDebounce = Timer(const Duration(seconds: 2), () {
          _typingDebounceActive = false;
        });
      }
    }
  }

  Future<void> _setup() async {
    final auth = context.read<AuthService>();
    final chat = context.read<ChatService>();
    final id = auth.active!.id;
    final peerId = widget.friend.identityId;

    // Initial backfill — fetch the full thread (both directions).
    try {
      final rows = await SupabaseBackend.fetchThread(peerId, null);
      for (final row in rows) {
        try {
          final m = await chat.decryptRow(row);
          _messages.add(m);
        } catch (_) {}
      }
      _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (mounted) setState(() {});
    } catch (_) {}

    // Realtime for incoming
    _channel = SupabaseBackend.subscribeMessages(
      identityId: id,
      onInsert: (row) async {
        if (row['from_identity'] != peerId) return;
        try {
          final m = await chat.decryptRow(row);
          if (_messages.any((e) => e.id == m.id)) return;
          _messages.add(m);
          _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          await SupabaseBackend.markDelivered(m.id);
          // markRead respects recipient's read-receipts setting server-side
          await SupabaseBackend.markRead(m.id);
          await HapticService.delivered();
          if (mounted) setState(() {});
          _scrollToBottom();
        } catch (_) {}
      },
    );

    // Typing indicator channel
    _typingChannel = SupabaseBackend.subscribeTyping(
      myId: id,
      peerId: peerId,
      onTyping: (typing) {
        if (typing) {
          setState(() => _peerTyping = true);
          _peerTypingTimer?.cancel();
          _peerTypingTimer = Timer(const Duration(seconds: 3), () {
            if (mounted) setState(() => _peerTyping = false);
          });
        } else {
          setState(() => _peerTyping = false);
        }
      },
    );

    // Fallback poll in case Realtime misses (every 5s — Realtime may be
    // filtered by RLS because we can't attach identity headers to the
    // websocket subscription in supabase_flutter 2.13.x, so polling is the
    // authoritative delivery path).
    _poll = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        final since = _messages.isEmpty ? null : _messages.last.createdAt;
        final rows = await SupabaseBackend.fetchThread(peerId, since);
        var added = false;
        for (final row in rows) {
          try {
            final m = await chat.decryptRow(row);
            if (_messages.any((e) => e.id == m.id)) continue;
            _messages.add(m);
            added = true;
            await SupabaseBackend.markDelivered(m.id);
            await SupabaseBackend.markRead(m.id);
          } catch (_) {}
        }
        if (added) {
          _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          if (mounted) setState(() {});
          _scrollToBottom();
        }
      } catch (_) {}
    });

    // Relay hop poll — if I'm an intermediary, process hops every 10s
    _relayPoll = Timer.periodic(OnionConfig.relayPollInterval, (_) async {
      try {
        await chat.processRelayHops();
      } catch (_) {}
    });
    // Fire once immediately
    try {
      await chat.processRelayHops();
    } catch (_) {}
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut);
        }
      });
    }
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _typingChannel?.unsubscribe();
    _poll?.cancel();
    _relayPoll?.cancel();
    _typingDebounce?.cancel();
    _peerTypingTimer?.cancel();
    _recordTimer?.cancel();
    _playerCompleteSub?.cancel();
    _playerPositionSub?.cancel();
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _scroll.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final auth = context.read<AuthService>();
    final chat = context.read<ChatService>();
    setState(() => _sending = true);
    _input.clear();
    // Stop typing indicator
    SupabaseBackend.broadcastTyping(
      myId: auth.active!.id,
      peerId: widget.friend.identityId,
      typing: false,
    );
    // Optimistic insert
    final optimistic = Message(
      id: 'pending-${DateTime.now().millisecondsSinceEpoch}',
      fromIdentity: auth.active!.id,
      toIdentity: widget.friend.identityId,
      plaintext: text,
      kind: MessageKind.text,
      createdAt: DateTime.now(),
      ttlSeconds: widget.friend.disappearingTtlSeconds ?? auth.disappearingDefault,
    );
    _messages.add(optimistic);
    setState(() {});
    _scrollToBottom();
    try {
      await chat.sendText(widget.friend.identityId, text);
      await HapticService.sent();
    } catch (e) {
      await HapticService.error();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Send failed: $e')));
        _messages.remove(optimistic);
        _input.text = text;
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    _sendAttachment(Uint8List.fromList(bytes), 'img', MessageKind.image);
  }

  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['pdf']);
    if (result == null) return;
    Uint8List bytes;
    if (result.files.single.bytes != null) {
      bytes = Uint8List.fromList(result.files.single.bytes!);
    } else if (result.files.single.path != null) {
      bytes = Uint8List.fromList(
          await File(result.files.single.path!).readAsBytes());
    } else {
      return;
    }
    _sendAttachment(bytes, 'pdf', MessageKind.pdf);
  }

  Future<void> _sendAttachment(
      Uint8List bytes, String ext, MessageKind kind) async {
    final chat = context.read<ChatService>();
    setState(() => _sending = true);
    try {
      await chat.sendAttachment(
        peerId: widget.friend.identityId,
        fileBytes: bytes,
        fileExt: ext,
        kind: kind,
        caption: '[${kind.name}]',
      );
      await HapticService.sent();
    } catch (e) {
      await HapticService.error();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ---------- voice recording ----------

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final dir = await getTemporaryDirectory();
        _recordPath =
            '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            bitRate: 128000,
            sampleRate: VoiceConfig.sampleRate,
          ),
          path: _recordPath!,
        );
        setState(() {
          _recording = true;
          _recordDuration = Duration.zero;
        });
        _recordTimer =
            Timer.periodic(const Duration(seconds: 1), (_) {
          setState(() => _recordDuration += const Duration(seconds: 1));
          if (_recordDuration >= VoiceConfig.maxDuration) {
            _stopRecording(send: true);
          }
        });
        await HapticService.light();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Mic error: $e')));
      }
    }
  }

  Future<void> _stopRecording({required bool send}) async {
    _recordTimer?.cancel();
    if (!_recording) return;
    final path = await _audioRecorder.stop();
    setState(() => _recording = false);
    if (send && path != null && _recordDuration.inSeconds >= 1) {
      final bytes = await File(path).readAsBytes();
      _sendAttachment(Uint8List.fromList(bytes), 'm4a', MessageKind.voice);
    }
    _recordDuration = Duration.zero;
    _recordPath = null;
  }

  Future<void> _cancelRecording() async {
    _recordTimer?.cancel();
    if (_recording) {
      try {
        await _audioRecorder.stop();
      } catch (_) {}
    }
    setState(() {
      _recording = false;
      _recordDuration = Duration.zero;
    });
    await HapticService.heavy();
  }

  Future<void> _playVoice(Message m) async {
    if (m.attachmentPath == null) return;
    // Stop any currently playing voice first
    if (_currentlyPlayingId != null && _currentlyPlayingId != m.id) {
      await _audioPlayer.stop();
      if (mounted) {
        setState(() {
          _playingVoice[_currentlyPlayingId!] = false;
          _voicePosition.remove(_currentlyPlayingId);
        });
      }
    }
    try {
      final bytes = await context.read<ChatService>().downloadAttachment(m);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/voice_${m.id}.m4a');
      await file.writeAsBytes(bytes);
      await _audioPlayer.play(DeviceFileSource(file.path));
      _currentlyPlayingId = m.id;
      if (mounted) setState(() => _playingVoice[m.id] = true);
      // Cancel previous subscriptions to prevent memory leaks / duplicate calls
      await _playerCompleteSub?.cancel();
      await _playerPositionSub?.cancel();
      _playerCompleteSub = _audioPlayer.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _playingVoice[m.id] = false;
            _voicePosition.remove(m.id);
            _currentlyPlayingId = null;
          });
        }
      });
      _playerPositionSub = _audioPlayer.onPositionChanged.listen((p) {
        if (mounted) {
          setState(() => _voicePosition[m.id] = p);
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Playback failed: $e')));
      }
    }
  }

  Future<void> _stopVoice() async {
    await _audioPlayer.stop();
    if (mounted) {
      setState(() {
        if (_currentlyPlayingId != null) {
          _playingVoice[_currentlyPlayingId!] = false;
        }
        _currentlyPlayingId = null;
      });
    }
  }

  Future<void> _showImage(Message m) async {
    try {
      final bytes = await context.read<ChatService>().downloadAttachment(m);
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              PhotoView(
                imageProvider: MemoryImage(bytes),
                backgroundDecoration: const BoxDecoration(color: Colors.black),
                minScale: PhotoViewComputedScale.contained,
                maxScale: PhotoViewComputedScale.covered * 3,
              ),
              Positioned(
                top: 36,
                right: 16,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to load image: $e')));
      }
    }
  }

  void _onLongPressMessage(Message m) {
    HapticService.longPress();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.attachmentPath != null && m.kind == MessageKind.image)
              ListTile(
                leading: const Icon(Icons.fullscreen),
                title: const Text('View image'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showImage(m);
                },
              ),
            if (m.fromIdentity == context.read<AuthService>().active!.id)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Delete for everyone'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _deleteMessage(m, true);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.orange),
              title: const Text('Delete for me'),
              onTap: () async {
                Navigator.pop(ctx);
                await _deleteMessage(m, false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy text'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: m.plaintext));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMessage(Message m, bool forEveryone) async {
    try {
      await SupabaseBackend.deleteMessage(m.id, forEveryone);
      if (mounted) {
        setState(() {
          if (forEveryone) {
            final i = _messages.indexWhere((e) => e.id == m.id);
            if (i >= 0) {
              _messages[i] = m.copyWith(
                plaintext: '🚫 Message deleted',
                deletedForEveryone: true,
              );
            }
          } else {
            _messages.removeWhere((e) => e.id == m.id);
          }
        });
        await HapticService.medium();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final f = auth.friend(widget.friend.identityId) ?? widget.friend;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(f.alias ?? f.identityId.substring(0, 8)),
            if (_peerTyping)
              const Text('typing…',
                  style: TextStyle(fontSize: 12, color: Colors.greenAccent))
            else if (f.onionRouted)
              const Text('onion-routed',
                  style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => _onMenuAction(v, f),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'alias', child: Text('Edit alias')),
              const PopupMenuItem(value: 'disappearing', child: Text('Disappearing')),
              PopupMenuItem(
                value: 'onion',
                child: Text(f.onionRouted
                    ? 'Disable onion routing'
                    : 'Enable onion routing'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const EmptyState(
                    icon: Icons.lock_outline,
                    title: 'No messages yet',
                    subtitle:
                        'Say hi — your messages are end-to-end encrypted\nand will disappear based on your settings.',
                  )
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final m = _messages[_messages.length - 1 - i];
                      final isMine = m.fromIdentity == auth.active!.id;
                      return _bubble(m, isMine);
                    },
                  ),
          ),
          if (_recording)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: Theme.of(context).colorScheme.surface,
              child: Row(
                children: [
                  const Icon(Icons.mic, color: Colors.red),
                  const SizedBox(width: 12),
                  Text(_formatDuration(_recordDuration),
                      style: const TextStyle(fontFeatures: [
                        FontFeature.tabularFigures(),
                      ])),
                  const Spacer(),
                  TextButton(
                    onPressed: _cancelRecording,
                    child: const Text('Cancel'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send, color: Colors.green),
                    onPressed: () => _stopRecording(send: true),
                  ),
                ],
              ),
            )
          else
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    IconButton(
                        icon: const Icon(Icons.image_outlined),
                        onPressed: _pickImage),
                    IconButton(
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        onPressed: _pickPdf),
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          hintText: 'Encrypted message…',
                          isDense: true,
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    GestureDetector(
                      onLongPress: _input.text.isEmpty
                          ? () => _stopRecording(send: true)
                          : null,
                      child: IconButton(
                        icon: _sending
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(_input.text.isEmpty
                                ? Icons.mic_none
                                : Icons.send),
                        onPressed: _sending
                            ? null
                            : () {
                                if (_input.text.isEmpty) {
                                  _startRecording();
                                } else {
                                  _send();
                                }
                              },
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _onMenuAction(String action, Friend f) async {
    final auth = context.read<AuthService>();
    switch (action) {
      case 'alias':
        final ctrl = TextEditingController(text: f.alias ?? '');
        final result = await showDialog<String>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Set alias'),
            content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(hintText: 'e.g. Alice'),
              maxLength: 50,
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                  child: const Text('Save')),
            ],
          ),
        );
        if (result != null) {
          await auth.updateFriend(f.copyWith(alias: result.isEmpty ? null : result));
          if (mounted) setState(() {});
        }
        break;
      case 'disappearing':
        final selected = await showDialog<int>(
          context: context,
          builder: (_) => SimpleDialog(
            title: const Text('Disappearing messages'),
            children: DisappearingConfig.presets.map((p) {
              return SimpleDialogOption(
                onPressed: () => Navigator.pop(context, p.seconds),
                child: Text(p.label),
              );
            }).toList(),
          ),
        );
        if (selected != null) {
          await auth.updateFriend(
              f.copyWith(disappearingTtlSeconds: selected));
          if (mounted) setState(() {});
        }
        break;
      case 'onion':
        await auth.updateFriend(f.copyWith(onionRouted: !f.onionRouted));
        if (mounted) setState(() {});
        break;
    }
  }

  Widget _bubble(Message m, bool isMine) {
    final theme = Theme.of(context);
    if (m.kind == MessageKind.system) {
      return Align(
        alignment: Alignment.center,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withOpacity(0.6),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(m.plaintext,
              style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: theme.textTheme.bodyMedium?.color)),
        ),
      );
    }

    return GestureDetector(
      onLongPress: () => _onLongPressMessage(m),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          decoration: BoxDecoration(
            color: isMine
                ? theme.colorScheme.primary
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (m.kind == MessageKind.image)
                _imageTile(m, isMine)
              else if (m.kind == MessageKind.voice)
                _voiceTile(m, isMine)
              else if (m.kind == MessageKind.pdf)
                _pdfTile(m, isMine),
              if (m.plaintext.isNotEmpty && m.kind != MessageKind.text)
                const SizedBox(height: 4),
              Text(
                m.plaintext.isEmpty && m.kind != MessageKind.text
                    ? ''
                    : m.plaintext,
                style: TextStyle(
                  fontSize: 15,
                  color: isMine ? Colors.white : theme.textTheme.bodyLarge?.color,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${m.createdAt.hour}:${m.createdAt.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                        fontSize: 10,
                        color: isMine ? Colors.white54 : theme.hintColor),
                  ),
                  if (isMine && m.readAt != null) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.done_all,
                        size: 12, color: theme.colorScheme.secondary),
                  ] else if (isMine && m.deliveredAt != null) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.done,
                        size: 12,
                        color: isMine ? Colors.white54 : theme.hintColor),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _imageTile(Message m, bool isMine) {
    return GestureDetector(
      onTap: () => _showImage(m),
      child: Container(
        height: 180,
        width: 220,
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(child: Icon(Icons.image, size: 32)),
      ),
    );
  }

  Widget _voiceTile(Message m, bool isMine) {
    final playing = _playingVoice[m.id] ?? false;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          onPressed: () {
            if (playing) {
              _stopVoice();
            } else {
              _playVoice(m);
            }
          },
        ),
        const SizedBox(width: 4),
        Icon(Icons.graphic_eq,
            size: 18, color: isMine ? Colors.white70 : Colors.black54),
      ],
    );
  }

  Widget _pdfTile(Message m, bool isMine) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.picture_as_pdf,
            size: 18, color: isMine ? Colors.white70 : Colors.black54),
        const SizedBox(width: 6),
        Text('PDF attached',
            style: TextStyle(
                fontSize: 12,
                color: isMine ? Colors.white70 : Colors.black54)),
      ],
    );
  }
}
