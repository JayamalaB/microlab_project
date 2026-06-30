import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:path_provider/path_provider.dart';
import 'package:microlab/theme/app_theme.dart';
import 'yt_web_stub.dart' if (dart.library.html) 'yt_web_impl.dart';

// ── Endpoints ─────────────────────────────────────────────────────────────────
const _kChatApiBase  = 'https://ai.neuralarc.com';
const _kVoiceApiBase = 'https://ai.neuralarc.com'; // STT + TTS (Node.js server)

// ── Promo config (mirrors index.html PROMO_CONFIG) ───────────────────────────
const _kYoutubeId      = 'gmUHEvrpYoU';
const _kYoutubeTitle   = 'NeuralArc – IoT & AI Solutions';
const _kYoutubeSub     = 'See how we build end-to-end smart systems for industry.';
const _kYoutubeChannel = 'NeuralArc Global';
// Asset paths — images live in client/assets/banners/ (bundled in the app)
const _kBannerUrls = [
  'assets/banners/banner1.jpg',
  'assets/banners/banner2.png',
  'assets/banners/banner3.png',
];

// ── Layer definitions ─────────────────────────────────────────────────────────
enum _Layer { all, staticInfo, db, web, book }

extension _LayerX on _Layer {
  String get apiKey => switch (this) {
        _Layer.all        => 'all',
        _Layer.staticInfo => 'static',
        _Layer.db         => 'db',
        _Layer.web        => 'web',
        _Layer.book       => 'book',
      };

  String get label => switch (this) {
        _Layer.all        => 'All',
        _Layer.staticInfo => 'Help & FAQ',
        _Layer.db         => 'Tests & Prices',
        _Layer.web        => 'About Lab',
        _Layer.book       => 'Book Test',
      };

  String get tagLabel => switch (this) {
        _Layer.all        => 'all',
        _Layer.staticInfo => 'help & faq',
        _Layer.db         => 'tests & prices',
        _Layer.web        => 'about lab',
        _Layer.book       => 'book test',
      };

  Color get accent => switch (this) {
        _Layer.staticInfo          => const Color(0xFF7C3AED),
        _Layer.db                  => const Color(0xFF059669),
        _Layer.web                 => const Color(0xFFEA580C),
        _Layer.all || _Layer.book  => AppColors.brandGreen,
      };

  Color get surface => switch (this) {
        _Layer.staticInfo          => const Color(0xFFFAF5FF),
        _Layer.db                  => const Color(0xFFF0FDF4),
        _Layer.web                 => const Color(0xFFFFF7ED),
        _Layer.all || _Layer.book  => AppColors.brandGreenSurface,
      };

  Color get chipBorder => switch (this) {
        _Layer.staticInfo          => const Color(0xFFC4B5FD),
        _Layer.db                  => const Color(0xFF6EE7B7),
        _Layer.web                 => const Color(0xFFFDBA74),
        _Layer.all || _Layer.book  => AppColors.brandGreenLight,
      };
}

// ── Branch data ───────────────────────────────────────────────────────────────
const _kBranches = [
  {'name': 'MicroLab – Coimbatore', 'address': 'Coimbatore, Tamil Nadu', 'phone': '0422 4354242 / 4354212', 'hours': 'Mon–Sat: 7:00 AM – 8:00 PM  ·  Sun: 8:00 AM – 2:00 PM'},
  {'name': 'MicroLab – Trichy',     'address': 'Trichy, Tamil Nadu',     'phone': '1800 425 1316 (Toll-Free)', 'hours': 'Mon–Sat: 7:00 AM – 8:00 PM  ·  Sun: 8:00 AM – 2:00 PM'},
];

const _kLocalChips = {
  'Branch Info', 'Test FAQs', 'Booking Help', 'Contact Us',
  'Coimbatore', 'Trichy', 'Other Branch',
  'Fasting needed?', 'Report timing?', 'How collection works?',
  'Cancel booking?', 'Reschedule?', 'Payment issue?', '← Back',
  // Static info layer FAQ chips — answered locally, no server needed
  'What tests do you offer?', 'What are your business hours?',
  'What payment methods do you accept?', 'How can I track my report?',
  'Are you NABL accredited?', 'Do you offer corporate packages?',
  'What are home collection charges?', 'Can I cancel my booking?', 'How do I reach support?',
  // Sample follow-up chips — answered locally
  'When will my report be ready?', 'How do I download my report?', 'Contact support',
};

// ── Local answers for static-info chips ─────────────────────────────────────
const _kStaticQALocal = <String, String>{
  'What tests do you offer?':
      '🧪 MicroLab Diagnostic Services:\n\n'
      '• Molecular Biology – DNA/RNA-based diagnostics for disease monitoring\n'
      '• Cytogenetics – Chromosomal analysis for genetic & oncological disorders\n'
      '• Serology – Antigen & antibody testing for infectious/autoimmune diseases\n'
      '• Microbiology – Culture, sensitivity & pathogen identification\n'
      '• Biochemistry – Routine biochemical testing\n'
      '• Clinical Pathology – Comprehensive pathological analysis\n\n'
      'For the full test brochure, visit microlabindia.com or call 0422 4354242.',

  'What are your business hours?':
      '🕐 MicroLab Hours:\n\n'
      '• Mon–Sat: 7:00 AM – 8:00 PM\n'
      '• Sunday: 8:00 AM – 2:00 PM\n\n'
      'Home sample collection is available during the same hours.\n'
      'For emergencies, call our toll-free: 1800 425 1316.',

  'What payment methods do you accept?':
      '💳 Accepted Payment Methods:\n\n'
      '• UPI — GPay, PhonePe, Paytm\n'
      '• Debit / Credit Cards (Visa, Mastercard, RuPay)\n'
      '• Net Banking\n'
      '• Cash at lab counter\n\n'
      'For online bookings, payment is made at the time of booking confirmation.',

  'How can I track my report?':
      '📱 Access Your Report Online:\n\n'
      '1. Visit microlabindiaonline.com → Patient Portal\n'
      '2. Log in with your patient credentials\n'
      '3. Download your report in PDF format\n\n'
      'You\'ll receive an SMS notification when your report is ready.\n'
      '• Routine tests: Same day / within 24 hours\n'
      '• Specialised tests: 24–72 hours',

  'Are you NABL accredited?':
      '✅ Quality & Accreditations:\n\n'
      'Microbiological Laboratory (MBL) is committed to:\n\n'
      '• Accuracy & Reliability – validated protocols, modern instruments, strict QC\n'
      '• Transparency & Ethics – complete integrity in testing and reporting\n'
      '• Innovation & Upgradation – continuous adoption of new diagnostic technologies\n\n'
      'For full accreditation details, visit microlabindia.com.',

  'Do you offer corporate packages?':
      '🏢 Corporate & Hospital Packages:\n\n'
      'Yes! MicroLab partners with hospitals, clinics, and corporates:\n\n'
      '• Dedicated Hospital / Doctor login portal for fast report access\n'
      '• Bulk testing at discounted rates\n'
      '• On-site / home collection at your premises\n'
      '• Paperless digital reports\n\n'
      'Contact: microlabcbe@microlabindia.com',

  'What are home collection charges?':
      '🚗 Home Sample Collection:\n\n'
      '• Safe & hygienic collection by trained phlebotomists\n'
      '• Collected at your doorstep — no need to visit the lab\n'
      '• Available Mon–Sat 7 AM – 8 PM, Sun 8 AM – 2 PM\n\n'
      'Call 0422 4354242 or WhatsApp 7904986636 to book and confirm charges.',

  'Can I cancel my booking?':
      '📋 Cancellation & Refund Policy:\n\n'
      '• Cancel before sample collection → full refund within 5–7 working days\n'
      '• After sample collection → no refund (processing has begun)\n'
      '• Home collection: cancel at least 2 hours before your scheduled slot\n\n'
      'For help: 0422 4354242 or WhatsApp 7904986636',

  'How do I reach support?':
      '📞 Contact MicroLab:\n\n'
      '• Phone: 0422 4354242 / 4354212\n'
      '• Toll-Free: 1800 425 1316\n'
      '• WhatsApp: 7904986636\n'
      '• Email: microlabcbe@microlabindia.com\n'
      '• Website: microlabindia.com\n\n'
      '⏰ Support hours: Mon–Sat 7:00 AM – 8:00 PM',
};

const _kLayerQs = <_Layer, List<String>>{
  _Layer.staticInfo: [
    'What tests do you offer?', 'What are your business hours?',
    'What payment methods do you accept?', 'How can I track my report?',
    'Are you NABL accredited?', 'Do you offer corporate packages?',
  ],
  _Layer.db: [
    'Show all available tests', 'What is the price of CBC test?',
    'List all branch locations', 'What tests are available for thyroid?',
    'Show Coimbatore branch details', 'Which tests require fasting?',
    'Track my sample status', 'Where is my report?',
  ],
  _Layer.web: [
    'What is Microbiological Laboratory (MBL)?',
    'What diagnostic services does MicroLab offer?',
    'Tell me about the Molecular Biology services',
    'What is the home sample collection process?',
    'How can I access my reports online?',
    'Who are the doctors at MicroLab?',
  ],
};

const _kFollowUps = <_Layer, List<String>>{
  _Layer.staticInfo: ['What are home collection charges?', 'Can I cancel my booking?', 'How do I reach support?'],
  _Layer.db:         ['What is the test preparation?', 'Show all branch locations', 'Which tests have no fasting?'],
  _Layer.web:        ['Tell me about the Cytogenetics department', "What are MicroLab's accreditations?", 'How do I book a home collection?'],
};

// Follow-ups by server intent — used when layer is "all"
const _kIntentFollowUps = <String, List<String>>{
  'test_query':    ['Which tests require fasting?', 'Show all branch locations', 'What is the price of CBC test?'],
  'branch_query':  ['Show Coimbatore branch details', 'What are your working hours?', 'How do I book a home collection?'],
  'default_qa':    ['What are home collection charges?', 'How can I track my report?', 'Can I cancel my booking?'],
  'website_live':  ["What are MicroLab's accreditations?", 'Tell me about home collection', 'Contact support'],
  'general':       ['What tests do you offer?', 'Show all branch locations', 'Book Test'],
};

const _kSampleFollowUps = [
  'When will my report be ready?',
  'How do I download my report?',
  'Contact support',
  'Show all available tests',
];

const _kTestPackages = [
  'Complete Blood Count (CBC)',
  'Lipid Profil e',
  'Liver Function Test (LFT)',
  'Kidney Function Test (KFT)',
  'Thyroid Profile (T3 / T4 / TSH)',
  'HbA1c (Glycated Hemoglobin)',
  'Blood Glucose – Fasting & PP',
  'Vitamin D (25-OH)',
  'Vitamin B12',
  'Urine Routine & Microscopy',
  'Molecular Biology Panel',
  'Serology Panel',
];

// ── Message model ─────────────────────────────────────────────────────────────
enum _MsgKind { normal, divider, bookingForm, patientLoginForm, layerSuggestion, promo }
enum _MicState { idle, recording, processing }

class _Msg {
  final String text;
  final bool isBot;
  final List<String>? chips;
  final _Layer layer;
  final _MsgKind kind;
  final String? voiceTranscript; // shown as pill when message came from mic

  const _Msg({
    this.text = '',
    this.isBot = true,
    this.chips,
    this.layer = _Layer.all,
    this.kind = _MsgKind.normal,
    this.voiceTranscript,
  });
}

// ── FAB ───────────────────────────────────────────────────────────────────────
class SupportChatbotButton extends StatelessWidget {
  /// Pass the logged-in patient's mobile / patient ID so the chatbot can
  /// filter sample-status queries to only this patient's records.
  final String? patientId;
  const SupportChatbotButton({super.key, this.patientId});

  void _open(BuildContext context) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _ChatbotSheet(patientId: patientId),
      );

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(28),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: AppColors.brandGreen,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: AppColors.brandGreen.withValues(alpha: 0.35),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.support_agent_rounded, color: Colors.white, size: 20),
              SizedBox(width: 7),
              Text('Help',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Chatbot sheet ─────────────────────────────────────────────────────────────
class _ChatbotSheet extends StatefulWidget {
  final String? patientId;
  const _ChatbotSheet({this.patientId});
  @override
  State<_ChatbotSheet> createState() => _ChatbotSheetState();
}

class _ChatbotSheetState extends State<_ChatbotSheet> {
  final _msgs   = <_Msg>[];
  final _ctrl   = TextEditingController();
  final _scroll = ScrollController();
  bool   _loading = false;
  _Layer _layer   = _Layer.all;
  final String _sid = 'ml_${DateTime.now().millisecondsSinceEpoch}';

  // Patient auth — set from widget.patientId (app login) or from inline form
  String? _verifiedPatientId;

  // Only matches questions specifically asking to TRACK/CHECK personal sample data.
  // Deliberately excludes "my report" alone to avoid catching FAQ follow-ups like
  // "When will my report be ready?" or "How do I download my report?".
  static bool _isSampleQuery(String text) => RegExp(
    r'\b(track my (sample|test|report)|sample status|check my sample|my sample status|where is my (sample|result)|my test result)\b',
    caseSensitive: false,
  ).hasMatch(text);

  // ── Mic / STT ──────────────────────────────────────────────────────────────
  late final AudioRecorder _recorder;
  _MicState _micState = _MicState.idle;
  StreamSubscription<Amplitude>? _amplitudeSub;
  Timer? _silenceTimer;

  // ── TTS ────────────────────────────────────────────────────────────────────
  late final AudioPlayer _ttsPlayer;
  bool _ttsLoading  = false;
  bool _ttsPlaying  = false;
  bool _ttsPaused   = false;
  int  _ttsForIdx   = -1;   // index in _msgs being spoken
  bool _ttsCancelled = false;
  Completer<void>? _ttsChunkCompleter;

  @override
  void initState() {
    super.initState();
    _verifiedPatientId = widget.patientId; // use app-level patient ID if available
    _recorder  = AudioRecorder();
    _ttsPlayer = AudioPlayer();
    _msgs.add(const _Msg(
      text: "Hi! I'm your MicroLab assistant 👋\n"
          "Tap a layer in the toolbar to get started, or just type — "
          "or tap 🎙️ to speak!",
      isBot: true,
      layer: _Layer.all,
    ));
    _msgs.add(const _Msg(kind: _MsgKind.promo)); // YouTube + banners
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    _amplitudeSub?.cancel();
    _silenceTimer?.cancel();
    _recorder.dispose();
    _ttsCancelled = true;
    _ttsChunkCompleter?.complete();
    _ttsPlayer.dispose();
    super.dispose();
  }

  // ── TTS helpers ────────────────────────────────────────────────────────────

  static String _cleanTtsText(String raw) {
    return raw
        // Remove emojis (covers most Unicode emoji blocks)
        .replaceAll(RegExp(r'[\u{1F300}-\u{1FAFF}]', unicode: true), '')
        .replaceAll(RegExp(r'[\u{2600}-\u{27BF}]', unicode: true), '')
        // Strip bold/italic markers while keeping inner text (Dart $1 is literal — must use replaceAllMapped)
        .replaceAllMapped(RegExp(r'\*\*(.*?)\*\*', dotAll: true), (m) => m.group(1) ?? '')
        .replaceAllMapped(RegExp(r'\*(.*?)\*', dotAll: true), (m) => m.group(1) ?? '')
        .replaceAll(RegExp(r'^\s*\d+\.\s+', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*[-–—•·]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'[←-⇿■-⛿✀-➿]'), '')
        // Pronunciation-friendly substitutions for Sarvam TTS (en-IN)
        .replaceAll('1800-XXX-XXXX', 'our toll-free number')
        .replaceAll(RegExp(r'X{3,}'), '')
        .replaceAll('₹', 'rupees ')
        .replaceAll('—', ', ')
        .replaceAll('–', ', ')
        .replaceAll('@', ' at ')
        // Remove stray leading punctuation left after bullet stripping
        .replaceAll(RegExp(r'^\s*[.:;]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }

  static List<String> _splitTtsChunks(String text, {int maxLen = 200}) {
    final sentences = RegExp(r'[^.!?\n]+[.!?\n]*')
        .allMatches(text)
        .map((m) => m.group(0)!.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final chunks = <String>[];
    var cur = '';
    for (final s in sentences) {
      final joined = cur.isEmpty ? s : '$cur $s';
      if (joined.length <= maxLen) {
        cur = joined;
      } else {
        if (cur.isNotEmpty) chunks.add(cur);
        if (s.length > maxLen) {
          for (var i = 0; i < s.length; i += maxLen) {
            final end = (i + maxLen) < s.length ? i + maxLen : s.length;
            chunks.add(s.substring(i, end));
          }
          cur = '';
        } else {
          cur = s;
        }
      }
    }
    if (cur.isNotEmpty) chunks.add(cur);
    return chunks.where((c) => c.isNotEmpty).toList();
  }

  Future<void> _playTts(int msgIdx, String text) async {
    _stopTts();

    final chunks = _splitTtsChunks(_cleanTtsText(text));
    if (chunks.isEmpty) return;

    setState(() { _ttsForIdx = msgIdx; _ttsLoading = true; });

    try {
      final res = await http.post(
        Uri.parse('$_kVoiceApiBase/speak-multi'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'chunks': chunks}),
      ).timeout(const Duration(seconds: 60));

      if (!mounted || _ttsCancelled) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['success'] == true) {
          final audios = (data['audios'] as List).cast<String>();
          setState(() { _ttsLoading = false; _ttsPlaying = true; });

          // On web: getTemporaryDirectory() and DeviceFileSource are unavailable.
          // Use BytesSource directly. On native: write to a temp file first.
          final Directory? tmpDir = kIsWeb ? null : await getTemporaryDirectory();

          for (var i = 0; i < audios.length; i++) {
            if (_ttsCancelled || !mounted) break;

            final bytes = base64Decode(audios[i]);

            final completer = Completer<void>();
            _ttsChunkCompleter = completer;

            late StreamSubscription sub;
            sub = _ttsPlayer.onPlayerComplete.listen((_) {
              sub.cancel();
              if (!completer.isCompleted) completer.complete();
            });

            if (kIsWeb) {
              await _ttsPlayer.play(BytesSource(bytes));
            } else {
              final tmpFile = File('${tmpDir!.path}/tts_chunk_$i.wav');
              await tmpFile.writeAsBytes(bytes);
              // Each WAV already has 250 ms of PCM silence prepended server-side,
              // so Android's AudioTrack initialises during that silence window —
              // no manual delay needed here.
              await _ttsPlayer.play(DeviceFileSource(tmpFile.path));
            }

            await completer.future
                .timeout(const Duration(seconds: 60), onTimeout: () {});
            sub.cancel();
            _ttsChunkCompleter = null;

            if (!kIsWeb) {
              try { await File('${tmpDir!.path}/tts_chunk_$i.wav').delete(); } catch (_) {}
            }

            // Between chunks: respect pause
            while (_ttsPaused && !_ttsCancelled) {
              await Future.delayed(const Duration(milliseconds: 50));
            }
          }
        }
      } else {
        // TTS is optional — log the failure but don't pollute the chat
        debugPrint('[TTS] speak-multi ${res.statusCode}: ${res.body.length > 200 ? res.body.substring(0, 200) : res.body}');
      }
    } catch (e) {
      if (mounted && !_ttsCancelled) {
        debugPrint('[TTS] $e');
      }
    }

    if (mounted) {
      setState(() {
        _ttsLoading  = false;
        _ttsPlaying  = false;
        _ttsPaused   = false;
        _ttsForIdx   = -1;
        _ttsCancelled = false;
      });
    }
  }

  void _stopTts() {
    _ttsCancelled = true;
    _ttsPlayer.stop();
    _ttsChunkCompleter?.complete();
    _ttsChunkCompleter = null;
    if (mounted) {
      setState(() {
        _ttsLoading = false;
        _ttsPlaying = false;
        _ttsPaused  = false;
        _ttsForIdx  = -1;
      });
    }
    // Reset for next call
    Future.microtask(() => _ttsCancelled = false);
  }

  void _toggleTtsPause() {
    setState(() => _ttsPaused = !_ttsPaused);
    if (_ttsPaused) {
      _ttsPlayer.pause();
    } else {
      _ttsPlayer.resume();
    }
  }

  // ── Mic / STT helpers ──────────────────────────────────────────────────────

  // Adds a bot error bubble — skips if the last message is already the same text
  void _addVoiceError(String msg) {
    if (!mounted) return;
    final last = _msgs.isNotEmpty ? _msgs.last : null;
    if (last != null && last.isBot && last.kind == _MsgKind.normal && last.text == msg) return;
    setState(() => _msgs.add(_Msg(text: msg, isBot: true, layer: _Layer.all)));
    _scrollBottom();
  }

  Future<void> _toggleMic() async {
    if (_micState == _MicState.recording) {
      await _stopRecording();
      return;
    }
    if (_micState != _MicState.idle) return;

    try {
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        _addVoiceError('Microphone access denied. Please allow microphone access in your device settings.');
        return;
      }
      // On web getTemporaryDirectory() throws MissingPluginException.
      // The record package ignores the path on web and returns a blob URL from stop().
      final String path = kIsWeb
          ? 'voice_${DateTime.now().millisecondsSinceEpoch}.wav'
          : '${(await getTemporaryDirectory()).path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';

      // Try with audio enhancements first; fall back if device doesn't support them.
      // autoGain/noiseSuppress/echoCancel require VOICE_COMMUNICATION audio source,
      // which some Android devices reject — hence the fallback.
      try {
        await _recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
            autoGain: true,
            noiseSuppress: true,
            echoCancel: true,
          ),
          path: path,
        );
      } catch (_) {
        await _recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: path,
        );
      }
      if (mounted) setState(() => _micState = _MicState.recording);

      // Give the user 600 ms to start speaking, then watch amplitude.
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted || _micState != _MicState.recording) return;

      _amplitudeSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 200))
          .listen((amp) {
        if (amp.current > -35.0) {
          // Speech detected — reset the silence timer.
          _silenceTimer?.cancel();
          _silenceTimer = null;
        } else if (_silenceTimer == null && _micState == _MicState.recording) {
          // Silence started — auto-stop after 1.5 s of quiet.
          _silenceTimer = Timer(const Duration(milliseconds: 1500), () {
            if (_micState == _MicState.recording && mounted) _stopRecording();
          });
        }
      });
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('permission') || msg.contains('denied') || msg.contains('notallowed')) {
        _addVoiceError('Microphone access denied. Please allow microphone access in your browser or device settings.');
      } else {
        _addVoiceError('Could not start the microphone. Please try again.');
      }
    }
  }

  Future<void> _stopRecording() async {
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    final path = await _recorder.stop();
    if (path != null && mounted) _transcribeAudio(path);
  }

  Future<void> _transcribeAudio(String path) async {
    setState(() => _micState = _MicState.processing);
    try {
      // On web, stop() returns a blob URL — fetch it with http.get().
      // On native, it's a real file path — read it with File.readAsBytes().
      final bytes = kIsWeb
          ? (await http.get(Uri.parse(path))).bodyBytes
          : await File(path).readAsBytes();

      if (bytes.isEmpty) {
        _addVoiceError("Couldn't capture audio. Please tap the mic and try again.");
        return;
      }

      final req = http.MultipartRequest('POST', Uri.parse('$_kVoiceApiBase/transcribe'));
      req.files.add(http.MultipartFile.fromBytes('audio', bytes, filename: 'voice.wav'));

      final streamed = await req.send().timeout(const Duration(seconds: 30));
      final body     = await streamed.stream.bytesToString();

      if (streamed.statusCode >= 500) {
        _addVoiceError('Voice server is temporarily unavailable. Please try again in a moment.');
        return;
      }

      final data     = jsonDecode(body) as Map<String, dynamic>;

      if (!mounted) return;

      if (data['success'] == true) {
        final transcript = (data['transcript'] as String?)?.trim() ?? '';
        if (transcript.isNotEmpty) {
          await _send(transcript, voiceTranscript: transcript);
        } else {
          _addVoiceError("I couldn't hear you clearly. Please tap the mic and try speaking again.");
        }
      } else {
        _addVoiceError(data['error'] as String? ?? 'Voice transcription failed. Please try again.');
      }
    } on SocketException {
      if (mounted) _addVoiceError('No connection to server. Please check your internet and try again.');
    } on TimeoutException {
      if (mounted) _addVoiceError('Voice server timed out. Please try again.');
    } catch (e) {
      if (mounted) {
        _addVoiceError('Voice recognition failed. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _micState = _MicState.idle);
      try { File(path).deleteSync(); } catch (_) {}
    }
  }

  // ── Chat send ──────────────────────────────────────────────────────────────

  void _scrollBottom() {
    Future.delayed(const Duration(milliseconds: 80), () {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
      }
    });
  }

  void _addDivider(String text) {
    setState(() => _msgs.add(_Msg(text: text, kind: _MsgKind.divider)));
    _scrollBottom();
  }

  void _pickLayer(_Layer l) {
    setState(() => _layer = l);
    if (l == _Layer.book) {
      _addDivider('Book Test selected');
      setState(() => _msgs.add(const _Msg(kind: _MsgKind.bookingForm, layer: _Layer.book)));
      _scrollBottom();
      return;
    }
    final qs = _kLayerQs[l] ?? [];
    _addDivider('${l.label} selected');
    setState(() => _msgs.add(_Msg(
      text: '✓ ${l.label} selected. Here are some things you can ask:',
      isBot: true,
      layer: l,
      chips: qs.take(6).toList(),
    )));
    _scrollBottom();
  }

  Future<void> _send(String text, {String? voiceTranscript}) async {
    if (text.trim().isEmpty) return;
    _stopTts();
    setState(() => _msgs.add(_Msg(
      text: text,
      isBot: false,
      layer: _layer,
      voiceTranscript: voiceTranscript,
    )));
    _scrollBottom();

    // Thank-you intercept — works from any layer, no server call needed.
    if (RegExp(r'^(thank\s*you|thanks|thank\s*u|ty|thx|great|awesome|perfect|wonderful)\b',
            caseSensitive: false)
        .hasMatch(text.trim())) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      setState(() => _msgs.add(const _Msg(
        text: "You're welcome! 😊 Let me know if there's anything else I can help you with.",
        isBot: true,
        layer: _Layer.all,
        chips: ['Show all available tests', 'Book a test', 'Find branch near me', 'Contact support'],
      )));
      _scrollBottom();
      setState(() => _loading = false);
      return;
    }

    if (_layer == _Layer.book) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      setState(() => _msgs.add(const _Msg(
        text: "You're in Book Test mode. Please use the form above, or switch layers using the toolbar.",
        isBot: true,
        layer: _Layer.book,
      )));
      _scrollBottom();
      return;
    }

    if (_kLocalChips.contains(text)) {
      await Future.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      setState(() => _msgs.add(_localReply(text)));
      _scrollBottom();
      return;
    }

    // If asking about personal sample/report and not yet authenticated, show login form
    if (_isSampleQuery(text) && _verifiedPatientId == null) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      setState(() => _msgs.add(_Msg(
        kind: _MsgKind.patientLoginForm,
        text: text, // stored so the form can retry the same question after auth
        isBot: true,
        layer: _Layer.db,
      )));
      _scrollBottom();
      return;
    }

    setState(() => _loading = true);
    _scrollBottom();

    try {
      final res = await http
          .post(
            Uri.parse('$_kChatApiBase/api/chat/ask'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'question': text,
              'session_id': _sid,
              'layer': _layer.apiKey,
              if (_verifiedPatientId != null) 'patient_id': _verifiedPatientId,
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;

      if (res.statusCode == 200) {
        final body    = jsonDecode(res.body) as Map<String, dynamic>;
        if (body['success'] == true) {
          final answer  = (body['data']?['answer'] as String?)?.trim() ?? 'No response.';
          final src     = body['data']?['context_used']?['source'] as String? ?? _layer.apiKey;
          final intent  = body['data']?['context_used']?['intent'] as String?;

          final dispLayer = (src == 'default_qa' || src == 'general_knowledge')
              ? _Layer.staticInfo
              // When user is on ALL, keep tag as ALL even if server used website
              : src == 'website_live' && _layer != _Layer.all
                  ? _Layer.web
                  : _layer == _Layer.all
                      ? _Layer.all
                      : _layer;

          final isNoMatch = intent == 'no_match'
              || answer.contains('No static Q&A match found')
              || answer.contains('no static Q&A match')
              || answer.contains("don't have specific information")
              || answer.contains("I don't have specific")
              || answer.contains('Access denied')
              || answer.contains('Sorry, I encountered an error')
              || answer.contains("couldn't find any information")
              || answer.contains("couldn't find any")
              || answer.contains("Couldn't retrieve relevant content")
              || answer.contains("Failed to synthesise")
              || answer.contains("Please call us")
              || answer.contains("Please visit our website");

          // Exclude the question that was just asked from its own answer's chips.
          final askedLower = text.trim().toLowerCase();
          List<String> _filterChips(List<String> pool) => (pool..shuffle())
              .where((c) => c.trim().toLowerCase() != askedLower)
              .take(3)
              .toList();

          final fus = isNoMatch
              ? <String>[]
              : intent == 'sample_status_query'
                  ? _filterChips(List<String>.from(_kSampleFollowUps))
                  : _layer != _Layer.all
                      ? _filterChips(List<String>.from(_kFollowUps[_layer] ?? []))
                      : _filterChips(List<String>.from(_kIntentFollowUps[intent] ?? []));

          final newMsgIdx = _msgs.length;

          setState(() {
            _loading = false;
            _msgs.add(_Msg(
              text: answer,
              isBot: true,
              layer: dispLayer,
              chips: fus.isEmpty ? null : fus,
              kind: isNoMatch ? _MsgKind.layerSuggestion : _MsgKind.normal,
            ));
          });
          _scrollBottom();

          // Auto-play TTS when the user spoke (voice input).
          // Extra 300 ms on top of the existing gap lets Android fully release
          // microphone audio focus before the speaker AudioTrack opens.
          if (voiceTranscript != null) {
            await Future.delayed(const Duration(milliseconds: 700));
            if (mounted) _playTts(newMsgIdx, answer);
          }
          return;
        }
      }
      setState(() {
        _loading = false;
        _msgs.add(_Msg(
          text: '⚠️ Something went wrong. Please try again.',
          isBot: true,
          layer: _Layer.all,
          kind: _layer != _Layer.all ? _MsgKind.layerSuggestion : _MsgKind.normal,
        ));
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _msgs.add(_Msg(
          text: '⚠️ Could not connect to the server. Check your connection.',
          isBot: true,
          layer: _Layer.all,
          kind: _layer != _Layer.all ? _MsgKind.layerSuggestion : _MsgKind.normal,
        ));
      });
    }
    _scrollBottom();
  }

  _Msg _localReply(String input) {
    // Check static FAQ map first
    final staticAnswer = _kStaticQALocal[input];
    if (staticAnswer != null) {
      return _Msg(
        text: staticAnswer,
        isBot: true,
        layer: _Layer.staticInfo,
        chips: const ['Branch Info', 'Test FAQs', 'Booking Help', '← Back'],
      );
    }

    switch (input) {
      case 'Branch Info':
        return const _Msg(text: 'Which branch would you like info about?', isBot: true, layer: _Layer.staticInfo, chips: ['Coimbatore', 'Trichy', '← Back']);
      case 'Test FAQs':
        return const _Msg(text: 'What would you like to know about tests?', isBot: true, layer: _Layer.staticInfo, chips: ['Fasting needed?', 'Report timing?', 'How collection works?', '← Back']);
      case 'Booking Help':
        return const _Msg(text: 'What do you need help with?', isBot: true, layer: _Layer.staticInfo, chips: ['Cancel booking?', 'Reschedule?', 'Payment issue?', '← Back']);
      case 'Contact Us':
        return const _Msg(text: '📞 Phone: 0422 4354242 / 4354212\n\n🆓 Toll-Free: 1800 425 1316\n\n💬 WhatsApp: 7904986636\n\n📧 Email: microlabcbe@microlabindia.com\n\n⏰ Mon–Sat, 7:00 AM – 8:00 PM', isBot: true, layer: _Layer.staticInfo, chips: ['Branch Info', '← Back']);
      case 'Coimbatore':
      case 'Trichy':
        final b = _kBranches.firstWhere(
          (br) => (br['name'] as String).contains(input),
          orElse: () => _kBranches[0],
        );
        return _Msg(
          text: '📍 ${b['name']}\n\nAddress: ${b['address']}\n\n📞 ${b['phone']}\n\n🕐 ${b['hours']}',
          isBot: true,
          layer: _Layer.staticInfo,
          chips: const ['Other Branch', 'Contact Us', '← Back'],
        );
      case 'Other Branch':
        return const _Msg(text: 'Choose a branch:', isBot: true, layer: _Layer.staticInfo, chips: ['Coimbatore', 'Trichy', '← Back']);
      case 'Fasting needed?':
        return const _Msg(text: 'Fasting (8–12 hrs) is required for:\n\n• HbA1c, Blood Glucose Fasting\n• Lipid Profile\n• Liver Function Test (LFT)\n\nCBC, Thyroid Profile, Vitamin D, Serology, and Molecular Biology tests can generally be done without fasting.\n\nAlways confirm with the lab when booking.', isBot: true, layer: _Layer.staticInfo, chips: ['Report timing?', '← Back']);
      case 'Report timing?':
        return const _Msg(text: '⏱ Report Turnaround:\n\n• Routine tests (CBC, Blood Sugar) — Same day / 24 hrs\n• Thyroid, LFT, KFT — 24 hrs\n• HbA1c, Vitamins — 24–48 hrs\n• Molecular Biology, Cytogenetics — 48–72 hrs\n\nYou\'ll get an SMS when your report is ready. Download from microlabindiaonline.com.', isBot: true, layer: _Layer.staticInfo, chips: ['Fasting needed?', '← Back']);
      case 'How collection works?':
        return const _Msg(text: '🏠 Home Collection:\n1. Book & choose a time slot\n2. Trained phlebotomist arrives at your door\n3. Sample collected safely & hygienically\n4. Sent to lab for processing\n5. Report available on patient portal\n\n🏥 Lab Visit:\n1. Walk in or book a slot\n2. Sample collected at the centre\n3. Download report from microlabindiaonline.com', isBot: true, layer: _Layer.staticInfo, chips: ['← Back']);
      case 'Cancel booking?':
        return const _Msg(text: 'To cancel your booking:\n\n1. Go to the "Bookings" tab in the app\n2. Open your booking\n3. Tap "Cancel Booking"\n\n• Before sample collection → full refund in 5–7 working days\n• After sample collection → no refund\n• Home collection: cancel at least 2 hrs before slot', isBot: true, layer: _Layer.staticInfo, chips: ['Reschedule?', '← Back']);
      case 'Reschedule?':
        return const _Msg(text: 'To reschedule, cancel your existing booking and create a new one with your preferred slot.\n\nFor assistance, call 0422 4354242 or WhatsApp 7904986636.', isBot: true, layer: _Layer.staticInfo, chips: ['Contact Us', '← Back']);
      case 'Payment issue?':
        return const _Msg(text: 'If payment was deducted but booking wasn\'t confirmed:\n\n1. Note your transaction ID\n2. Email microlabcbe@microlabindia.com with your booking ID and payment screenshot\n3. Or call 0422 4354242\n\nWe\'ll resolve it within 24 hours.', isBot: true, layer: _Layer.staticInfo, chips: ['Contact Us', '← Back']);
      case 'When will my report be ready?':
        return const _Msg(
          text: '⏱ Typical report turnaround times:\n\n'
              '• Routine tests (CBC, Blood Sugar) — Same day / within 24 hrs\n'
              '• Thyroid, LFT, KFT — 24 hrs\n'
              '• HbA1c, Vitamins — 24–48 hrs\n'
              '• Molecular Biology, Cytogenetics — 48–72 hrs\n\n'
              'You will receive an SMS once your report is ready.',
          isBot: true, layer: _Layer.staticInfo,
          chips: ['How do I download my report?', 'Track my sample status', 'Contact support'],
        );
      case 'How do I download my report?':
        return const _Msg(
          text: '📱 Downloading your report:\n\n'
              '1. Visit microlabindiaonline.com → Patient Portal\n'
              '2. Log in with your patient credentials\n'
              '3. Select your test from the dashboard\n'
              '4. Tap "Download Report" to save as PDF\n\n'
              'You can also collect a physical copy at any branch.',
          isBot: true, layer: _Layer.staticInfo,
          chips: ['When will my report be ready?', 'Track my sample status', 'Contact support'],
        );
      case 'Contact support':
        return const _Msg(
          text: '📞 MicroLab Support:\n\n'
              '• Coimbatore: 0422 4354242 / 4354212\n'
              '• Trichy (Toll-free): 1800 425 1316\n'
              '• WhatsApp: 7904986636\n'
              '• Email: microlabcbe@microlabindia.com\n\n'
              '🕐 Support hours: Mon–Sat 7:00 AM – 8:00 PM',
          isBot: true, layer: _Layer.staticInfo,
          chips: ['Track my sample status', 'Show all available tests', '← Back'],
        );
      case '← Back':
        return const _Msg(text: 'Sure! What else can I help you with?', isBot: true, layer: _Layer.all, chips: ['Branch Info', 'Test FAQs', 'Booking Help', 'Contact Us']);
      default:
        return const _Msg(text: "I didn't quite get that. Please choose an option or type your question.", isBot: true, layer: _Layer.all, chips: ['Branch Info', 'Test FAQs', 'Booking Help', 'Contact Us']);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    // Wrap with Padding so the sheet slides UP when the keyboard opens,
    // keeping the input bar visible above the keyboard at all times.
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardHeight),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.88,
        decoration: const BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            _buildHeader(),
            _buildLayerToolbar(),
            Expanded(child: _buildMessages()),
            _buildInput(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: const BoxDecoration(
        color: AppColors.brandGreen,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.28), width: 1.5),
            ),
            child: const Icon(Icons.support_agent_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('MicroLab Assistant',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          const _PulseDot(),
          const SizedBox(width: 5),
          const Text('Online',
              style: TextStyle(color: Color(0xFF7EFFA0), fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          _LayerMenu(onLayerSelected: _pickLayer),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
            onPressed: () => Navigator.pop(context),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
        ],
      ),
    );
  }

  Widget _buildLayerToolbar() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          Expanded(child: _LayerChip(layer: _Layer.staticInfo, onTap: () => _pickLayer(_Layer.staticInfo))),
          const SizedBox(width: 5),
          Expanded(child: _LayerChip(layer: _Layer.db,         onTap: () => _pickLayer(_Layer.db))),
          const SizedBox(width: 5),
          Expanded(child: _LayerChip(layer: _Layer.web,        onTap: () => _pickLayer(_Layer.web))),
          const SizedBox(width: 5),
          Expanded(child: _LayerChip(layer: _Layer.book,       onTap: () => _pickLayer(_Layer.book))),
        ],
      ),
    );
  }

  Widget _buildMessages() {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: _msgs.length + (_loading ? 1 : 0),
      itemBuilder: (_, i) {
        if (_loading && i == _msgs.length) return _buildTypingIndicator();
        final msg = _msgs[i];
        return switch (msg.kind) {
          _MsgKind.divider          => _buildDivider(msg.text),
          _MsgKind.promo            => _buildPromoBlock(),
          _MsgKind.bookingForm      => _buildBookingFormMsg(),
          _MsgKind.patientLoginForm => _buildPatientLoginForm(msg),
          _MsgKind.layerSuggestion  => _buildLayerSuggestionMsg(msg, i),
          _MsgKind.normal           => _buildBubble(msg, i),
        };
      },
    );
  }

  Widget _buildDivider(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  Colors.transparent,
                  AppColors.brandGreenLight.withValues(alpha: 0.7),
                  Colors.transparent,
                ]),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(text.toUpperCase(),
                style: const TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary, letterSpacing: 0.7)),
          ),
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  Colors.transparent,
                  AppColors.brandGreenLight.withValues(alpha: 0.7),
                  Colors.transparent,
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Promo block: YouTube card + banner carousel ───────────────────────────
  Widget _buildPromoBlock() {
    return const Padding(
      padding: EdgeInsets.only(bottom: 16),
      child: Column(
        children: [
          _YoutubeCard(),
          SizedBox(height: 10),
          _BannerCarousel(imageUrls: _kBannerUrls),
        ],
      ),
    );
  }

  Widget _buildPatientLoginForm(_Msg msg) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BotAvatar(),
          const SizedBox(width: 8),
          Expanded(
            child: _PatientLoginForm(
              originalQuestion: msg.text,
              onVerified: (pid) {
                setState(() {
                  _verifiedPatientId = pid;
                  // Replace the form message with a compact verified badge
                  // so the form never re-renders in this session.
                  final idx = _msgs.indexOf(msg);
                  if (idx != -1) {
                    _msgs[idx] = const _Msg(
                      text: '🔐 Identity verified',
                      isBot: true,
                      layer: _Layer.db,
                    );
                  }
                });
                _send(msg.text);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBookingFormMsg() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BotAvatar(),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SourceTag(layer: _Layer.book),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: AppColors.brandGreenLight),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4), topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(18), bottomRight: Radius.circular(18),
                    ),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4)],
                  ),
                  child: _BookingForm(
                    apiBase: _kChatApiBase,
                    onBooked: () {
                      setState(() => _msgs.add(const _Msg(
                        text: 'Your booking has been received! Is there anything else I can help you with?',
                        isBot: true,
                        layer: _Layer.book,
                        chips: ['Show all available tests', 'Find branch near me', 'Contact support', 'Book another test'],
                      )));
                      _scrollBottom();
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLayerSuggestionMsg(_Msg msg, int idx) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BotAvatar(),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _SourceTag(layer: msg.layer),
                    const Spacer(),
                    _TtsButton(
                      msgIdx: idx, text: msg.text,
                      isLoading:  _ttsForIdx == idx && _ttsLoading,
                      isPlaying:  _ttsForIdx == idx && _ttsPlaying && !_ttsPaused,
                      isPaused:   _ttsForIdx == idx && _ttsPaused,
                      onPlay:      () => _playTts(idx, msg.text),
                      onPause:     _toggleTtsPause,
                      onStop:      _stopTts,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: AppColors.divider),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4), topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(18), bottomRight: Radius.circular(18),
                    ),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4)],
                  ),
                  child: Text(msg.text,
                      style: const TextStyle(fontSize: 13, height: 1.65, color: AppColors.textPrimary)),
                ),
                const SizedBox(height: 8),
                const Text('TRY ANOTHER LAYER:',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary, letterSpacing: 0.5)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6, runSpacing: 6,
                  children: [_Layer.staticInfo, _Layer.db, _Layer.web, _Layer.book, _Layer.all]
                      .where((l) => l != _layer)
                      .map((l) => GestureDetector(
                            onTap: () {
                              setState(() => _layer = l);
                              _addDivider('${l.label} selected');
                              if (l == _Layer.book) {
                                setState(() => _msgs.add(const _Msg(kind: _MsgKind.bookingForm, layer: _Layer.book)));
                              } else if (l == _Layer.all) {
                                setState(() => _msgs.add(const _Msg(
                                  text: '✓ Switched to All Layers.',
                                  isBot: true, layer: _Layer.all,
                                )));
                              } else {
                                setState(() => _msgs.add(_Msg(
                                  text: '✓ Switched to ${l.label}. Try your question again.',
                                  isBot: true, layer: l,
                                  chips: _kLayerQs[l]?.take(4).toList(),
                                )));
                              }
                              _scrollBottom();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                              decoration: BoxDecoration(
                                color: l.surface,
                                border: Border.all(color: l.chipBorder, width: 1.5),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(_switchLabel(l),
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: l.accent)),
                            ),
                          ))
                      .toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _switchLabel(_Layer l) => switch (l) {
        _Layer.staticInfo => '❓ Help & FAQ',
        _Layer.db         => '🧪 Tests & Prices',
        _Layer.web        => '🏥 About Lab',
        _Layer.book       => '🩺 Book Test',
        _Layer.all        => '🔍 Everything',
      };

  Widget _buildBubble(_Msg msg, int idx) {
    // User bubble
    if (!msg.isBot) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Voice transcript pill
            if (msg.voiceTranscript != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.brandGreenSurface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.brandGreenLight),
                ),
                child: Text('🎙️ "${msg.voiceTranscript}"',
                    style: const TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: AppColors.brandGreen)),
              ),
              const SizedBox(height: 4),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.brandGreen,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(18), topRight: Radius.circular(18),
                        bottomLeft: Radius.circular(18), bottomRight: Radius.circular(4),
                      ),
                      boxShadow: [BoxShadow(
                          color: AppColors.brandGreen.withValues(alpha: 0.28),
                          blurRadius: 14, offset: const Offset(0, 3))],
                    ),
                    child: Text(msg.text,
                        style: const TextStyle(fontSize: 13, height: 1.65, color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 34, height: 34,
                  decoration: const BoxDecoration(color: Color(0xFF374151), shape: BoxShape.circle),
                  child: const Center(
                    child: Text('You',
                        style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // Bot bubble
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BotAvatar(),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _SourceTag(layer: msg.layer),
                    const Spacer(),
                    _TtsButton(
                      msgIdx: idx, text: msg.text,
                      isLoading:  _ttsForIdx == idx && _ttsLoading,
                      isPlaying:  _ttsForIdx == idx && _ttsPlaying && !_ttsPaused,
                      isPaused:   _ttsForIdx == idx && _ttsPaused,
                      onPlay:     () => _playTts(idx, msg.text),
                      onPause:    _toggleTtsPause,
                      onStop:     _stopTts,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: AppColors.divider),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(4), topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(18), bottomRight: Radius.circular(18),
                    ),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4)],
                  ),
                  child: Text(msg.text,
                      style: const TextStyle(fontSize: 13, height: 1.65, color: AppColors.textPrimary)),
                ),
                if (msg.chips != null && msg.chips!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 7, runSpacing: 7,
                    children: msg.chips!.map((c) => GestureDetector(
                      onTap: _loading ? null : () => _send(c),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.brandGreenSurface,
                          border: Border.all(
                            color: _loading ? AppColors.divider : AppColors.brandGreenLight,
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(c,
                            style: TextStyle(
                                fontSize: 11.5, fontWeight: FontWeight.w500,
                                color: _loading ? AppColors.textHint : AppColors.brandGreen)),
                      ),
                    )).toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BotAvatar(),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: AppColors.brandGreenSurface,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(4), topRight: Radius.circular(14),
                bottomLeft: Radius.circular(14), bottomRight: Radius.circular(14),
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TypingDot(color: AppColors.brandGreen, delay: Duration.zero),
                SizedBox(width: 4),
                _TypingDot(color: AppColors.brandGreenMid, delay: Duration(milliseconds: 180)),
                SizedBox(width: 4),
                _TypingDot(color: AppColors.brandGreen, delay: Duration(milliseconds: 360)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInput() {
    final isRecording  = _micState == _MicState.recording;
    final isProcessing = _micState == _MicState.processing;

    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 10, 12, MediaQuery.of(context).padding.bottom + 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              textInputAction: TextInputAction.send,
              style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
              enabled: !_loading && !isProcessing,
              decoration: InputDecoration(
                hintText: isRecording  ? 'Listening…'
                        : isProcessing ? 'Transcribing…'
                        : _loading     ? 'Thinking…'
                        : 'Ask something, or tap 🎙️ to speak…',
                hintStyle: const TextStyle(fontSize: 13, color: AppColors.textHint),
                filled: true,
                fillColor: AppColors.background,
                contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: AppColors.divider, width: 1.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: AppColors.divider),
                ),
              ),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty && !_loading) {
                  _send(v.trim());
                  _ctrl.clear();
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          // Mic button
          _MicButtonWidget(
            micState: _micState,
            onTap: _toggleMic,
          ),
          const SizedBox(width: 6),
          // Send button
          GestureDetector(
            onTap: (_loading || isProcessing)
                ? null
                : () {
                    if (_ctrl.text.trim().isNotEmpty) {
                      _send(_ctrl.text.trim());
                      _ctrl.clear();
                    }
                  },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: (_loading || isProcessing) ? AppColors.divider : AppColors.brandGreen,
                shape: BoxShape.circle,
                boxShadow: (_loading || isProcessing)
                    ? []
                    : [BoxShadow(
                        color: AppColors.brandGreen.withValues(alpha: 0.35),
                        blurRadius: 10, offset: const Offset(0, 3))],
              ),
              child: Icon(Icons.send_rounded,
                  color: (_loading || isProcessing) ? AppColors.textHint : Colors.white, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Bot avatar ────────────────────────────────────────────────────────────────
class _BotAvatar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34, height: 34,
      decoration: BoxDecoration(
        color: AppColors.brandGreen,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(
            color: AppColors.brandGreen.withValues(alpha: 0.35),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: const Icon(Icons.support_agent_rounded, color: Colors.white, size: 18),
    );
  }
}

// ── Source tag ────────────────────────────────────────────────────────────────
class _SourceTag extends StatelessWidget {
  final _Layer layer;
  const _SourceTag({required this.layer});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      decoration: BoxDecoration(
        color: layer.surface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(layer.tagLabel.toUpperCase(),
          style: TextStyle(
              fontSize: 9.5, fontWeight: FontWeight.w700,
              color: layer.accent, letterSpacing: 0.6)),
    );
  }
}

// ── TTS button ────────────────────────────────────────────────────────────────
class _TtsButton extends StatelessWidget {
  final int    msgIdx;
  final String text;
  final bool   isLoading;
  final bool   isPlaying;
  final bool   isPaused;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onStop;

  const _TtsButton({
    required this.msgIdx,
    required this.text,
    required this.isLoading,
    required this.isPlaying,
    required this.isPaused,
    required this.onPlay,
    required this.onPause,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    Widget icon;
    Color  bg;
    VoidCallback action;

    if (isLoading) {
      icon   = const SizedBox(
        width: 12, height: 12,
        child: CircularProgressIndicator(
            strokeWidth: 1.5, color: AppColors.brandGreen));
      bg     = AppColors.brandGreenSurface;
      action = () {};
    } else if (isPlaying) {
      icon   = const Icon(Icons.pause_rounded, size: 14, color: Colors.white);
      bg     = AppColors.brandGreen;
      action = onPause;
    } else if (isPaused) {
      icon   = const Icon(Icons.play_arrow_rounded, size: 14, color: AppColors.brandGreen);
      bg     = AppColors.brandGreenSurface;
      action = onPause; // toggles resume
    } else {
      icon   = const Icon(Icons.volume_up_rounded, size: 14, color: AppColors.brandGreen);
      bg     = AppColors.brandGreenSurface;
      action = onPlay;
    }

    return GestureDetector(
      onTap: action,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.brandGreenLight),
        ),
        child: Center(child: icon),
      ),
    );
  }
}

// ── Mic button ────────────────────────────────────────────────────────────────
class _MicButtonWidget extends StatelessWidget {
  final _MicState  micState;
  final VoidCallback onTap;
  const _MicButtonWidget({required this.micState, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isRecording  = micState == _MicState.recording;
    final isProcessing = micState == _MicState.processing;

    Color bg   = AppColors.brandGreenSurface;
    Color fg   = AppColors.brandGreen;
    Color bd   = AppColors.brandGreenLight;
    IconData ic = Icons.mic_rounded;

    if (isRecording) {
      bg = const Color(0x1ADC2626);
      fg = const Color(0xFFDC2626);
      bd = const Color(0x66DC2626);
      ic = Icons.stop_rounded;
    } else if (isProcessing) {
      bg = const Color(0x1AEAB308);
      fg = const Color(0xFFB45309);
      bd = const Color(0x66EAB308);
      ic = Icons.hourglass_bottom_rounded;
    }

    return GestureDetector(
      onTap: isProcessing ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 42, height: 42,
        decoration: BoxDecoration(
          color: bg, shape: BoxShape.circle,
          border: Border.all(color: bd, width: 1.5),
        ),
        child: Icon(ic, color: fg, size: 20),
      ),
    );
  }
}

// ── Online pulse dot ──────────────────────────────────────────────────────────
class _PulseDot extends StatefulWidget {
  const _PulseDot();
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double>   _a;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat(reverse: true);
    _a = Tween<double>(begin: 0.4, end: 1.0)
        .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _a,
      child: Container(
        width: 7, height: 7,
        decoration: const BoxDecoration(color: Color(0xFF4ADE80), shape: BoxShape.circle),
      ),
    );
  }
}

// ── Typing dot ────────────────────────────────────────────────────────────────
class _TypingDot extends StatefulWidget {
  final Color    color;
  final Duration delay;
  const _TypingDot({required this.color, required this.delay});
  @override
  State<_TypingDot> createState() => _TypingDotState();
}

class _TypingDotState extends State<_TypingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double>   _a;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
      ..repeat(reverse: true);
    _a = Tween<double>(begin: 0.3, end: 1.0)
        .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));
    if (widget.delay != Duration.zero) {
      _c.stop();
      Future.delayed(widget.delay, () { if (mounted) _c.repeat(reverse: true); });
    }
  }

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _a,
        child: Container(
          width: 7, height: 7,
          decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
        ),
      );
}

// ── 3-dot layer menu ──────────────────────────────────────────────────────────
class _LayerMenu extends StatelessWidget {
  final void Function(_Layer) onLayerSelected;
  const _LayerMenu({required this.onLayerSelected});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_Layer>(
      icon: Container(
        width: 34, height: 34,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.26), width: 1.5),
        ),
        child: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 18),
      ),
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 4,
      offset: const Offset(0, 8),
      onSelected: onLayerSelected,
      itemBuilder: (_) => [
        _item(_Layer.staticInfo, '1. Info You Need'),
        _item(_Layer.db,         '2. My Orders'),
        _item(_Layer.web,        '3. About Us'),
        _item(_Layer.book,       '4. Book Test'),
      ],
    );
  }

  PopupMenuItem<_Layer> _item(_Layer l, String label) {
    return PopupMenuItem(
      value: l,
      child: Row(
        children: [
          Container(width: 8, height: 8,
              decoration: BoxDecoration(color: l.accent, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        ],
      ),
    );
  }
}

// ── Layer chip ────────────────────────────────────────────────────────────────
class _LayerChip extends StatelessWidget {
  final _Layer     layer;
  final VoidCallback onTap;
  const _LayerChip({required this.layer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        decoration: BoxDecoration(
          color: layer.surface,
          border: Border.all(color: layer.chipBorder, width: 1.5),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(width: 6, height: 6,
                decoration: BoxDecoration(color: layer.accent, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                layer.label,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: layer.accent),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── YouTube card ──────────────────────────────────────────────────────────────
// Shows a static thumbnail initially. On tap, swaps in a YouTube embed WebView
// (youtube.com/embed) with playsinline=1 so the video plays inside the card
// without full-screening or navigating away.
class _YoutubeCard extends StatefulWidget {
  const _YoutubeCard();
  @override
  State<_YoutubeCard> createState() => _YoutubeCardState();
}

class _YoutubeCardState extends State<_YoutubeCard> {
  static const _videoId  = _kYoutubeId;
  static const _watchUrl = 'https://www.youtube.com/watch?v=$_videoId';
  static const _thumbUrl = 'https://img.youtube.com/vi/$_videoId/hqdefault.jpg';
  bool _playing = false;
  WebViewController? _ctrl;

  void _startPlaying() {
    // On web we render an <iframe> directly (see yt_web_impl.dart) so the
    // allow="autoplay" attribute is set — no WebViewController needed.
    if (kIsWeb) {
      setState(() => _playing = true);
      return;
    }

    final ctrl = WebViewController();

    final platform = ctrl.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }

    // Load a local HTML page that hosts the YouTube <iframe>.
    // YouTube checks the Referer header — loading embed/ directly from a WebView
    // exposes the package origin and triggers Error 153. Serving via loadHtmlString
    // with a real domain as baseUrl makes YouTube see a proper website referrer.
    final embedHtml = '''<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{background:#000;overflow:hidden}
  iframe{position:fixed;top:0;left:0;width:100%;height:100%;border:none}
</style>
</head>
<body>
<iframe
  src="https://www.youtube.com/embed/$_videoId?autoplay=1&rel=0&playsinline=1"
  allow="autoplay;fullscreen;encrypted-media;picture-in-picture"
  allowfullscreen>
</iframe>
</body>
</html>''';

    ctrl
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          if (req.isMainFrame && !req.url.contains('youtube.com')) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadHtmlString(embedHtml, baseUrl: 'https://www.microlabindia.com');

    setState(() {
      _ctrl = ctrl;
      _playing = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            child: SizedBox(
              height: 210,
              width: double.infinity,
              child: _playing
                  ? (kIsWeb
                      ? buildYtWebPlayer(_videoId)
                      : WebViewWidget(controller: _ctrl!))
                  : GestureDetector(
                      onTap: _startPlaying,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.network(
                            _thumbUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(color: Colors.black),
                          ),
                          Center(
                            child: Container(
                              width: 60, height: 60,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 38,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF0000),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 18),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_kYoutubeTitle,
                          style: TextStyle(fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.white),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      SizedBox(height: 2),
                      Text('$_kYoutubeChannel · $_kYoutubeSub',
                          style: TextStyle(fontSize: 10.5,
                              color: Colors.white70),
                          maxLines: 2),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => launchUrl(Uri.parse(_watchUrl),
                      mode: LaunchMode.externalApplication),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.brandGreenSurface,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text('Open ↗',
                        style: TextStyle(fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.brandGreen)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Banner carousel ───────────────────────────────────────────────────────────
class _BannerCarousel extends StatefulWidget {
  final List<String> imageUrls;
  const _BannerCarousel({required this.imageUrls});
  @override
  State<_BannerCarousel> createState() => _BannerCarouselState();
}

class _BannerCarouselState extends State<_BannerCarousel> {
  final _controller = PageController();
  int   _current    = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      final next = (_current + 1) % widget.imageUrls.length;
      _controller.animateToPage(next,
          duration: const Duration(milliseconds: 420), curve: Curves.easeInOut);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int idx) {
    _controller.animateToPage(
      idx % widget.imageUrls.length,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 190,
        child: Stack(
          children: [
            // Slides — uses Image.asset for bundled files, Image.network for URLs
            PageView.builder(
              controller: _controller,
              onPageChanged: (i) => setState(() => _current = i),
              itemCount: widget.imageUrls.length,
              itemBuilder: (_, i) {
                final url = widget.imageUrls[i];
                final isAsset = !url.startsWith('http');
                return isAsset
                    ? Image.asset(url,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        errorBuilder: (_, __, ___) => _brokenBanner())
                    : Image.network(url,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        errorBuilder: (_, __, ___) => _brokenBanner());
              },
            ),

            // Prev
            Positioned(
              left: 8, top: 0, bottom: 0,
              child: Center(child: _navBtn(Icons.chevron_left_rounded, () {
                _timer?.cancel();
                _goTo(_current - 1 + widget.imageUrls.length);
              })),
            ),

            // Next
            Positioned(
              right: 8, top: 0, bottom: 0,
              child: Center(child: _navBtn(Icons.chevron_right_rounded, () {
                _timer?.cancel();
                _goTo(_current + 1);
              })),
            ),

            // Dots
            Positioned(
              bottom: 10, left: 0, right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(widget.imageUrls.length, (i) =>
                  GestureDetector(
                    onTap: () { _timer?.cancel(); _goTo(i); },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _current ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == _current ? Colors.white : Colors.white60,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _brokenBanner() => Container(
    color: const Color(0xFFEEEEEE),
    child: const Center(
      child: Icon(Icons.broken_image_outlined, size: 40, color: Colors.grey),
    ),
  );

  Widget _navBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.88),
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 4)],
        ),
        child: Icon(icon, size: 16, color: const Color(0xFF222222)),
      ),
    );
  }
}

// ── Booking form ──────────────────────────────────────────────────────────────
class _BookingForm extends StatefulWidget {
  final String apiBase;
  final VoidCallback? onBooked;
  const _BookingForm({required this.apiBase, this.onBooked});
  @override
  State<_BookingForm> createState() => _BookingFormState();
}

class _BookingFormState extends State<_BookingForm> {
  final _name  = TextEditingController();
  final _age   = TextEditingController();
  final _phone = TextEditingController();
  String? _pkg;
  bool    _loading = false;
  bool    _success = false;
  String? _error;
  List<String> _packages = [];
  bool _packagesLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPackages();
  }

  Future<void> _loadPackages() async {
    try {
      final res = await http.get(
        Uri.parse('${widget.apiBase}/api/chat/products'),
      ).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (body['data'] as List).cast<String>();
        setState(() { _packages = list; _packagesLoading = false; });
      } else {
        setState(() { _packages = _kTestPackages; _packagesLoading = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _packages = _kTestPackages; _packagesLoading = false; });
    }
  }

  @override
  void dispose() {
    _name.dispose(); _age.dispose(); _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name  = _name.text.trim();
    final age   = _age.text.trim();
    final phone = _phone.text.trim();

    if (name.isEmpty || age.isEmpty || phone.isEmpty || _pkg == null) {
      setState(() => _error = 'Please fill in all fields.');
      return;
    }
    if (!RegExp(r'^\d{7,15}$').hasMatch(phone)) {
      setState(() => _error = 'Enter a valid phone number (7–15 digits).');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final res = await http.post(
        Uri.parse('${widget.apiBase}/api/chat/book-test'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name, 'age': age, 'phone': phone, 'package': _pkg}),
      ).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (res.statusCode >= 200 && res.statusCode < 300) {
        setState(() => _success = true);
        widget.onBooked?.call();
      } else {
        final body = jsonDecode(res.body) as Map<String, dynamic>?;
        setState(() => _error = body?['error'] as String? ?? 'Server error (${res.statusCode}).');
      }
    } on TimeoutException {
      if (mounted) setState(() => _error = 'Request timed out. Please try again.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the server. Check your connection.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_success) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.brandGreenSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.brandGreenLight, width: 1.5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.check_circle_rounded, color: AppColors.brandGreen, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Booking confirmed for ${_name.text.trim()} — $_pkg.\nOur team will reach you shortly.',
                style: const TextStyle(fontSize: 12.5, color: AppColors.brandGreen,
                    fontWeight: FontWeight.w600, height: 1.5),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('🩺 Book a Test',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.brandGreen)),
        const SizedBox(height: 12),
        _field('Full Name',     _name,  TextInputType.name,  'e.g. Ravi Kumar'),
        const SizedBox(height: 10),
        _field('Age',           _age,   TextInputType.number, 'e.g. 28'),
        const SizedBox(height: 10),
        _field('Phone Number',  _phone, TextInputType.phone, 'e.g. 9876543210'),
        const SizedBox(height: 10),
        const Text('Test Package',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        const SizedBox(height: 4),
        _packagesLoading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Row(children: [
                  SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2,
                          color: AppColors.brandGreen)),
                  SizedBox(width: 10),
                  Text('Loading packages…',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ]),
              )
            : DropdownButtonFormField<String>(
                value: _pkg,
                hint: const Text('— Select a package —',
                    style: TextStyle(fontSize: 12.5, color: AppColors.textHint)),
                isExpanded: true,
                decoration: InputDecoration(
                  filled: true, fillColor: AppColors.background,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: AppColors.divider, width: 1.5)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
                ),
                items: _packages.map((p) =>
                    DropdownMenuItem(value: p, child: Text(p, style: const TextStyle(fontSize: 12.5)))).toList(),
                onChanged: (v) => setState(() => _pkg = v),
              ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFCA5A5)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline_rounded, color: Color(0xFFDC2626), size: 15),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(_error!,
                      style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626), height: 1.4)),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        ElevatedButton(
          onPressed: _loading ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.brandGreen, foregroundColor: Colors.white,
            disabledBackgroundColor: AppColors.divider,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            elevation: 2,
          ),
          child: _loading
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('Submit Booking',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }

  Widget _field(String label, TextEditingController c, TextInputType type, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11.5,
            fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        const SizedBox(height: 4),
        TextField(
          controller: c, keyboardType: type,
          style: const TextStyle(fontSize: 12.5, color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 12.5, color: AppColors.textHint),
            filled: true, fillColor: AppColors.background,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9),
                borderSide: const BorderSide(color: AppColors.divider, width: 1.5)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9),
                borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
          ),
        ),
      ],
    );
  }
}

// ── Patient login form (inline in chat) ───────────────────────────────────────
class _PatientLoginForm extends StatefulWidget {
  final String originalQuestion;
  final void Function(String patientId) onVerified;

  const _PatientLoginForm({
    required this.originalQuestion,
    required this.onVerified,
  });

  @override
  State<_PatientLoginForm> createState() => _PatientLoginFormState();
}

class _PatientLoginFormState extends State<_PatientLoginForm> {
  final _idCtrl  = TextEditingController();
  final _pwCtrl  = TextEditingController();
  bool _loading  = false;
  bool _obscure  = true;
  bool _verified = false;
  String? _error;

  @override
  void dispose() {
    _idCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final pid = _idCtrl.text.trim();
    final pwd = _pwCtrl.text.trim();
    if (pid.isEmpty || pwd.isEmpty) {
      setState(() => _error = 'Please enter both Patient ID and password.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final res = await http.post(
        Uri.parse('$_kChatApiBase/api/chat/verify-patient'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'patient_id': pid, 'password': pwd}),
      ).timeout(const Duration(seconds: 15));

      if (!mounted) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200 && body['success'] == true) {
        setState(() { _verified = true; _loading = false; });
        await Future.delayed(const Duration(milliseconds: 600));
        widget.onVerified(body['patient_id'].toString());
      } else {
        setState(() {
          _loading = false;
          _error = body['error'] as String? ?? 'Invalid credentials. Please try again.';
        });
      }
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = 'Connection error. Please try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_verified) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.brandGreenSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.brandGreenLight),
        ),
        child: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: AppColors.brandGreen, size: 18),
            SizedBox(width: 8),
            Flexible(child: Text('Verified! Fetching your sample status…',
                style: TextStyle(color: AppColors.brandGreen, fontSize: 13, fontWeight: FontWeight.w500))),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            children: [
              Icon(Icons.lock_outline_rounded, size: 16, color: AppColors.brandGreen),
              SizedBox(width: 6),
              Flexible(child: Text('Patient Login', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.textPrimary))),
            ],
          ),
          const SizedBox(height: 4),
          const Text('Enter your Patient ID and password to continue.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 14),
          // Patient ID
          TextField(
            controller: _idCtrl,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Patient ID',
              labelStyle: const TextStyle(fontSize: 13),
              prefixIcon: const Icon(Icons.badge_outlined, size: 18),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.brandGreen),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Password
          TextField(
            controller: _pwCtrl,
            obscureText: _obscure,
            keyboardType: TextInputType.text,
            style: const TextStyle(fontSize: 14),
            onSubmitted: (_) => _verify(),
            decoration: InputDecoration(
              labelText: 'Password',
              labelStyle: const TextStyle(fontSize: 13),
              prefixIcon: const Icon(Icons.lock_outline, size: 18),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.brandGreen),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.error_outline, size: 14, color: Color(0xFFD32F2F)),
                const SizedBox(width: 5),
                Flexible(child: Text(_error!, style: const TextStyle(fontSize: 12, color: Color(0xFFD32F2F)))),
              ],
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 42,
            child: ElevatedButton(
              onPressed: _loading ? null : _verify,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandGreen,
                disabledBackgroundColor: AppColors.brandGreen.withValues(alpha: 0.4),
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: _loading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Verify & Continue', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}
