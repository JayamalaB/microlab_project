import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:microlab/theme/app_theme.dart';
import 'yt_web_stub.dart' if (dart.library.html) 'yt_web_impl.dart';

// ── Endpoints ─────────────────────────────────────────────────────────────────
const _kChatApiBase  = 'https://chat.neuralarc.com';
const _kVoiceApiBase = 'https://chat.neuralarc.com'; // STT + TTS (Node.js server)

// ── Promo config (mirrors index.html PROMO_CONFIG) ───────────────────────────
// Flip to true to bring the YouTube promo card back — banner carousel is unaffected.
const _kShowYoutubePromo = false;
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

const _kFaqCategoryNames = [
  'General Info', 'Testing Info', 'Payment Info', 'Booking Info', 'Branch Locations',
];

// ── FAQ categories — mirrors the official MicroLab FAQ sheet ────────────────
const _kFaqCategories = <String, List<String>>{
  'General Info': [
    'What sample collection services does Microlab offer?',
    'Can I reschedule my appointment?',
    'What is the timing for sample collection?',
    'How do I locate the nearest Microlab branch?',
    'What are your Lab working hours?',
    'What should I bring when visiting the laboratory?',
    'What specialities are being offered at Microlab?',
    'Mention the specialities',
    'How can I contact Microlab Customer Support?',
  ],
  'Testing Info': [
    'How can I book a lab test?',
    'Is fasting required before blood tests?',
    "Can I book a test without a doctor's prescription?",
    'Do you offer health checkup packages?',
    'Is there a preparation procedure for Master Health Checkup?',
    'Can children and senior citizens undergo testing at Microlab?',
    'How long does it take to receive test reports?',
    'How can I access my test reports?',
    'Do you offer online report downloads?',
  ],
  'Payment Info': [
    'What payment methods are accepted?',
    'Do you accept corporate and insurance-related testing?',
  ],
  'Booking Info': [
    'What if I need to cancel a test after booking?',
    'What is the cancellation policy if the technician is already on the way?',
    'How do refunds work for pre-paid bookings?',
    'How do I verify the identity of the technician visiting my home?',
    'Can I book multiple tests in one visit?',
    'Can I book for someone else (family member)?',
    "I didn't receive my report — what should I do?",
    'Can I track my home collection technician?',
  ],
  'Branch Locations': [
    'Does Microlab have a branch in Coimbatore?',
    'Where is the Microlab Head Office?',
    'How many Microlab branches are there across India?',
    'Is Microlab available outside Tamil Nadu?',
    'Does Microlab have a branch in Chennai?',
    'Does Microlab have a branch in Salem?',
    'Does Microlab have a branch in Trichy?',
    'Does Microlab have a branch in Madurai?',
    'Does Microlab have a branch in Erode?',
    'Does Microlab have a branch in Tirupur?',
    'Does Microlab have a branch in Ooty?',
  ],
};

final Set<String> _kLocalChips = {
  ..._kFaqCategoryNames,
  '← Back',
  // Static info layer FAQ chips — answered locally, no server needed
  for (final qs in _kFaqCategories.values) ...qs,
  // Report follow-up chips — answered locally
  'When will my report be ready?', 'How do I download my report?', 'Contact support',
  // About Lab layer chips — answered locally so web scraping failure never shows "no info"
  'What is Microbiological Laboratory (MBL)?',
  'What diagnostic services does MicroLab offer?',
  'Tell me about the Molecular Biology services',
  'Tell me about the Cytogenetics department',
  "What are MicroLab's accreditations?",
  'Who are the doctors at MicroLab?',
  'How can I access my reports online?',
  'What is the home sample collection process?',
  'How do I book a home collection?',
};

// ── Local answers for static-info chips ─────────────────────────────────────
const _kStaticQALocal = <String, String>{
  'What sample collection services does Microlab offer?':
      '🧪 Sample Collection Services:\n\n'
      'We offer:\n'
      '1. General lab visit\n'
      '2. Appointment / Priority-based lab visit\n'
      '3. Home sample collection',

  'Can I reschedule my appointment?':
      '📅 Rescheduling:\n\n'
      'Yes. Appointments can be rescheduled by contacting our customer support team via phone, WhatsApp, or by visiting your nearest Microlab branch.\n\n'
      'We recommend informing us at least 6 hours in advance.',

  'What is the timing for sample collection?':
      '⏰ Sample Collection Timing:\n\n'
      'For tests/profiles requiring prior fasting, 6:00 AM to 11:00 AM is the ideal time-slot.\n\n'
      'For non-fasting tests/profiles, you can choose any time-slot till 5:00 PM.',

  'How do I locate the nearest Microlab branch?':
      '📍 Locate a Branch:\n\n'
      'You can find your nearest Microlab Laboratory branch through:\n'
      '1. Our website\'s Branch Locator\n'
      '2. Google Maps\n'
      '3. Customer Care Helpline\n'
      '4. WhatsApp Support',

  'What are your Lab working hours?':
      '🕐 Lab Working Hours:\n\n'
      'Our operating hours may vary by branch. Please contact your nearest Microlab centre or check our website — you can also check Google Maps for updated timings.',

  'What should I bring when visiting the laboratory?':
      '🩺 What to Bring:\n\n'
      'Please bring: Doctor\'s prescription (if available).',

  'What specialities are being offered at Microlab?':
      '🔬 Our Specialities:\n\n'
      'We are a leading multi-disciplinary laboratory in India. We have more than 10 departments.',

  'Mention the specialities':
      '🔬 MicroLab Departments:\n\n'
      '1. Molecular Biology\n2. Microbiology\n3. Histopathology\n4. Cytogenetics\n5. Genetics\n'
      '6. Oncology\n7. Biochemistry\n8. Serology\n9. Clinical Pathology\n10. Hematology',

  'How can I contact Microlab Customer Support?':
      '📞 Contact MicroLab Customer Support:\n\n'
      'Phone – 0422 4354242\nWhatsApp\nEmail – microlabcbe@microlabindia.com',

  'How can I book a lab test?':
      '🧾 Booking a Lab Test:\n\n'
      'You can book your test through:\n1. Phone Call\n2. WhatsApp\n3. Visit our nearest MBL branch',

  'Is fasting required before blood tests?':
      '🍽️ Fasting Requirements:\n\n'
      'Some tests require fasting while others do not. Our team will inform you about any preparation needed when you book your test.',

  "Can I book a test without a doctor's prescription?":
      '📝 Booking Without a Prescription:\n\n'
      'Yes, health/general checkups can be booked without a prescription. Certain specialised tests may require a doctor\'s recommendation.',

  'Do you offer health checkup packages?':
      '📦 Health Checkup Packages:\n\n'
      'Yes. We offer 5 comprehensive, exclusive health checkup packages.',

  'Is there a preparation procedure for Master Health Checkup?':
      '✅ Master Health Checkup Preparation:\n\n'
      'To ensure accurate test results:\n'
      '1. Fast for 10–12 hours before your appointment (water is allowed unless instructed otherwise).\n'
      '2. Avoid alcohol and non-veg meals the day before.',

  'Can children and senior citizens undergo testing at Microlab?':
      '👨‍👩‍👧‍👦 Testing for All Ages:\n\n'
      'Yes, we offer tests for all age groups.',

  'How long does it take to receive test reports?':
      '⏱ Report Turnaround:\n\n'
      'Report delivery depends on the test type:\n'
      '1. Routine tests — within 6 hours or same day\n'
      '2. Specialised tests — 1–3 working days\n'
      '3. Advanced tests — as per test requirement',

  'How can I access my test reports?':
      '📄 Accessing Your Reports:\n\n'
      'Reports can be received through: Email, WhatsApp, Online Patient Portal, or a printed copy from the laboratory.',

  'Do you offer online report downloads?':
      '📱 Online Report Downloads:\n\n'
      'Yes. Patients can securely access and download their reports online through our patient web portal. '
      'Reports can also be shared via email or WhatsApp upon request.',

  'What payment methods are accepted?':
      '💳 Accepted Payment Methods:\n\n'
      'We accept multiple payment options for your convenience:\n'
      '1. Cash\n2. Credit & Debit Cards\n3. UPI Payments (Google Pay, PhonePe, Paytm, etc.)',

  'Do you accept corporate and insurance-related testing?':
      '🏢 Corporate & Insurance Testing:\n\n'
      'No, we are not authorised for insurance-related testing.',

  'What if I need to cancel a test after booking?':
      '❌ Cancelling After Booking:\n\n'
      'You can cancel your test booking through the app at any time before the technician starts their journey for sample collection.',

  'What is the cancellation policy if the technician is already on the way?':
      '🚗 Cancellation — Technician En Route:\n\n'
      'If the technician has already reached your location and the appointment is cancelled, the home collection service charge will be deducted.\n\n'
      'Any remaining amount, if applicable, will be processed according to the laboratory\'s refund policy.',

  'How do refunds work for pre-paid bookings?':
      '💰 Refunds for Pre-Paid Bookings:\n\n'
      'Refunds are processed based on the cancellation policy:\n'
      '• Cancelled before the technician starts the journey → full refund\n'
      '• Technician already reached your location → home collection service charge deducted, remaining amount (if any) refunded\n\n'
      'Refunds are typically credited to the original payment method within the applicable processing time.',

  'How do I verify the identity of the technician visiting my home?':
      '🪪 Verifying the Technician:\n\n'
      'You can verify the technician\'s identity by viewing their photo and details in the app before the scheduled visit.',

  'Can I book multiple tests in one visit?':
      '🧪 Multiple Tests, One Visit:\n\nYes, you can book multiple tests.',

  'Can I book for someone else (family member)?':
      '👪 Booking for Family Members:\n\nYes, you can book for family members.',

  "I didn't receive my report — what should I do?":
      '📞 Report Not Received?\n\n'
      'You can reach us via:\nPhone – 0422 4354242\nWhatsApp\nEmail – microlabcbe@microlabindia.com',

  'Can I track my home collection technician?':
      '🚚 Tracking Your Technician:\n\nYes, you can track your home collection technician in the app.',

  'Does Microlab have a branch in Coimbatore?':
      '📍 MicroLab – Coimbatore:\n\n'
      'Yes. Coimbatore is our headquarters city with 15+ branches including RS Puram (Head Office – 24 hrs), '
      'Ganapathy, Peelamedu, Ramanathapuram, Vadavalli, Saravanampatti, Selvapuram, Kuniyamuthur, Kovaiputhur, '
      'Nehru Nagar, Thudiyalur, Jothipuram, KNG Pudur, Sulur, and SVSA.',

  'Where is the Microlab Head Office?':
      '🏢 MicroLab Head Office:\n\n'
      'No. 12A, Cowley Brown Road, RS Puram (E), Coimbatore – 641002\n'
      'Phone: 0422 4354242 / 2540525 / 2556628 / 2550673\nOpen: 24 Hours',

  'How many Microlab branches are there across India?':
      '🇮🇳 Branches Across India:\n\n'
      'Microlab has 50+ branches across India spanning Tamil Nadu, Karnataka, Kerala, Andhra Pradesh, '
      'Telangana, Maharashtra, Delhi NCR, Haryana, West Bengal, Assam, and more.',

  'Is Microlab available outside Tamil Nadu?':
      '🗺️ Beyond Tamil Nadu:\n\n'
      'Yes. We have branches in:\n\n'
      'Karnataka: Bangalore (3 locations), Mysuru, Mangalore, Hosur\n'
      'Kerala: Palakkad, Cochin, Thiruvananthapuram\n'
      'Andhra Pradesh/Telangana: Hyderabad, Vijayawada, Chittoor\n'
      'Maharashtra: Mumbai, Pune\n'
      'North India: Delhi NCR (Noida), Gurugram\n'
      'Others: Kolkata, Nagpur, Assam',

  'Does Microlab have a branch in Chennai?':
      '📍 MicroLab – Chennai:\n\n'
      'Yes. 115/18, Main Road, Y Block Main Road (Opp. to Tower Park Road), Anna Nagar, Chennai – 600040\n'
      'Phone: 044-43500217\nMobile: 9344847160\nEmail: microlabchennai@gmail.com',

  'Does Microlab have a branch in Salem?':
      '📍 MicroLab – Salem:\n\n'
      'Yes. 2nd Floor, Vangalamman Tower Building, Opp. Pranav Hospital, No. 77/2, Brindhavan Road, Fairlands, Salem – 636004\n'
      'Phone: 0427-4262775\nMobile: 9362129153\nEmail: microlabsalem@gmail.com',

  'Does Microlab have a branch in Trichy?':
      '📍 MicroLab – Trichy:\n\n'
      'Yes. Two locations in Trichy:\n\n'
      'KK Nagar: No. 24 & 25, Shanthi Guru Towers, EVR Road, KK Nagar Bus Stand – 620021 | Ph: 0431 2352151\n'
      'EVR Salai: 3/28, Plot No. 200, EVR Salai, KK Nagar – 620021 | Ph: 0431 3554312',

  'Does Microlab have a branch in Madurai?':
      '📍 MicroLab – Madurai:\n\n'
      'Yes. No. 368-C, Bharathiyar Apartment, 80 Feet Road, Anna Nagar, Madurai – 625020\n'
      'Phone: 0452-4390408\nMobile: 9840924080\nEmail: microlabqcmadurai@gmail.com',

  'Does Microlab have a branch in Erode?':
      '📍 MicroLab – Erode:\n\n'
      'Yes. 33/4, Chinnamuthu 2nd Street, Old Natesar Mill Area, EK Valasu, Perundurai Road, Erode – 638011\n'
      'Phone: 0424-2250739\nMobile: 9842915881\nEmail: microlabqcerode@gmail.com',

  'Does Microlab have a branch in Tirupur?':
      '📍 MicroLab – Tirupur:\n\n'
      'Yes. No. 471/291, Opp. to Geetha Pharmacy, Near Pushpa Bus Stop, Avinashi Road, Tirupur – 641602\n'
      'Phone: 0421 224 2266\nMobile: 6385238852\nEmail: tirupur.micro720@gmail.com',

  'Does Microlab have a branch in Ooty?':
      '📍 MicroLab – Ooty:\n\n'
      'Yes. 393/302, Rathina Complex, Ettines Road, Opp. to Aavin, Bombay Castle, Ooty – 643001\n'
      'Phone: 0423-2440673\nMobile: 9843863586\nEmail: microlabooty1@gmail.com',
};

const _kLayerQs = <_Layer, List<String>>{
  _Layer.staticInfo: _kFaqCategoryNames,
  _Layer.db: [
    'Show all available tests', 'What is the price of CBC test?',
    'List all branch locations', 'What tests are available for thyroid?',
    'Show Coimbatore branch details', 'Which tests require fasting?',
    'My booking', 'Booking history',
  ],
  _Layer.web: [
    'What is Microbiological Laboratory (MBL)?',
    'What diagnostic services does MicroLab offer?',
    'Tell me about the Molecular Biology services',
    'Tell me about the Cytogenetics department',
    "What are MicroLab's accreditations?",
    'How do I book a home collection?',
  ],
};

const _kFollowUps = <_Layer, List<String>>{
  _Layer.staticInfo: ['General Info', 'Testing Info', 'Branch Locations'],
  _Layer.db:         ['What is the test preparation?', 'Show all branch locations', 'Which tests have no fasting?'],
  _Layer.web:        ['Who are the doctors at MicroLab?', 'How can I access my reports online?', 'What is the home sample collection process?'],
};

// Follow-ups by server intent — used when layer is "all"
const _kIntentFollowUps = <String, List<String>>{
  'test_query':    ['Which tests require fasting?', 'Show all branch locations', 'What is the price of CBC test?'],
  'branch_query':  ['Show Coimbatore branch details', 'What are your working hours?', 'How do I book a home collection?'],
  'default_qa':    ['General Info', 'Testing Info', 'Branch Locations'],
  'website_live':  ["What are MicroLab's accreditations?", 'Tell me about home collection', 'Contact support'],
  'general':       ['General Info', 'Show all branch locations', 'Book Test'],
};

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
  /// scope profile, booking, and technician queries to this patient's own records.
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
          width: 44,
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
          child: const Icon(Icons.support_agent_rounded, color: Colors.white, size: 22),
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

  // Matches questions about the patient's own profile/family members (ip_patients) or
  // account/subscription (ip_clients) — mirrors PATIENT_PROFILE_PATTERN,
  // FAMILY_SCOPE_PATTERN, and BARE_RELATION_PATTERN in server/rag/llmRetriever.js so
  // both layers agree on what needs authentication. Includes plain-language synonyms
  // for "profile" ("my information", "my data", "my details") since patients don't
  // always use that exact word, and a bare relation word/"family" as a short follow-up
  // after the bot lists family members (e.g. just typing "sister" or "mother").
  static bool _isPatientAccountQuery(String text) {
    const relationWords =
        'mother|father|spouse|wife|husband|child|children|son|daughter|sister|brother';
    const infoWords = 'info|information|data|details|records?';

    final isBareRelation = RegExp(
      "^\\s*($relationWords|family)'?s?\\s*[?.!]?\\s*\$",
      caseSensitive: false,
    ).hasMatch(text);
    if (isBareRelation) return true;

    return RegExp(
      "\\b(family members?|my patients?|patients? (on|under|in) my account|my profile|patient profile|"
      "my ($infoWords)|my (blood group|dob|date of birth)|"
      "my ($relationWords)'?s?|my family|family ($infoWords)|"
      "my subscription|subscription (tier|plan)|my (account status|membership)|is my account active|client account)\\b",
      caseSensitive: false,
    ).hasMatch(text);
  }

  // Matches questions about the patient's own bookings (ip_bookings) — mirrors
  // BOOKING_QUERY_PATTERN in server/rag/llmRetriever.js, including "last/past/previous
  // [N] bookings" phrasing. Deliberately requires "booking(s)" so it doesn't collide
  // with the Book Test flow ("book a test").
  static bool _isBookingQuery(String text) {
    const countWord =
        r'\d+|one|two|three|four|five|six|seven|eight|nine|ten|couple(?: of)?|few';
    return RegExp(
      "\\b(my bookings?|bookings?\\s*(details|info(rmation)?|status|history)|"
      "(latest|recent)\\s*bookings?|(last|past|previous)\\s*($countWord)?\\s*bookings?|"
      "track my booking|booking ref(erence)?|(all|show|list)\\s*(my\\s*)?bookings)\\b",
      caseSensitive: false,
    ).hasMatch(text);
  }

  // Matches questions about the technician assigned to a booking (ip_technicians) —
  // mirrors TECHNICIAN_QUERY_PATTERN in server/rag/llmRetriever.js.
  static bool _isTechnicianQuery(String text) => RegExp(
    r"\b(technician\s*(info(rmation)?|details|name|contact|status)|who(?:'s| is) my technician|"
    r'which technician|assigned technician|my technician)\b',
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
    _verifiedPatientId = widget.patientId;
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
        // Collapse blank lines but keep the break itself — a plain space here
        // would merge the last field of one branch/booking into the next
        // one's name, since formatBranchInfo() etc. separate entries with \n\n.
        .replaceAll(RegExp(r'\n{2,}'), '\n')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .trim();
  }

  // Each \n-separated line (branch name / mobile / working hours / next
  // branch / ...) is its own hard chunk boundary — never merged with a
  // neighbouring line even if short — so the pause _playTts already applies
  // between chunks lands after every field, not just once ~200 chars have
  // piled up across several fields.
  static List<String> _splitTtsChunks(String text, {int maxLen = 200}) {
    final chunks = <String>[];
    for (final line in text.split('\n')) {
      final trimmedLine = line.trim();
      if (trimmedLine.isEmpty) continue;

      final sentences = RegExp(r'[^.!?]+[.!?]*')
          .allMatches(trimmedLine)
          .map((m) => m.group(0)!.trim())
          .where((s) => s.isNotEmpty)
          .toList();
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
    }
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
        // Sarvam STT auto-detects the spoken language ('language_code' in the
        // response) — only Tamil gets threaded through as voiceLanguage, so
        // the server knows to translate at the /ask boundary.
        final detectedLang = data['language_code'] as String?;
        if (transcript.isNotEmpty) {
          await _send(transcript,
              voiceTranscript: transcript,
              voiceLanguage: detectedLang == 'ta-IN' ? detectedLang : null);
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

  // voiceLanguage is set only for voice input Sarvam detected as Tamil
  // ('ta-IN') — typed messages and English voice input never set it, so the
  // server's translate-at-boundary step (chat.js) only runs for Tamil speech.
  Future<void> _send(String text, {String? voiceTranscript, String? voiceLanguage}) async {
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
        text: 'That question is better answered in a different section. Switch to the right layer:',
        isBot: true,
        layer: _Layer.book,
        kind: _MsgKind.layerSuggestion,
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

    // If asking about personal profile/family, account/subscription, booking, or
    // technician data and not yet authenticated, show the login form instead of sending
    // to the server (which would just reply with a plain "please log in" text bubble).
    if ((_isPatientAccountQuery(text) || _isBookingQuery(text) || _isTechnicianQuery(text)) &&
        _verifiedPatientId == null) {
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
              if (voiceLanguage != null) 'language': voiceLanguage,
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
          final errCode = body['data']?['context_used']?['error'] as String?;
          // Server-provided chips (e.g. the branch state picker) — shown as-is,
          // bypassing the static follow-up suggestion pools below.
          final serverChips = (body['data']?['context_used']?['chips'] as List?)
              ?.map((e) => e.toString())
              .toList();

          // Server says this needs a verified patient (profile/account/booking/technician)
          // but we sent none — show the login form instead of a dead-end text reply.
          // This is a safety net for phrasing the client-side pre-checks miss (e.g. a
          // bare "bookings"), since the server always sets this flag for any
          // personal-data intent regardless of exact wording.
          if (errCode == 'no_patient_id') {
            setState(() {
              _loading = false;
              _msgs.add(_Msg(
                kind: _MsgKind.patientLoginForm,
                text: text, // original question, so the form can retry it after auth
                isBot: true,
                layer: _layer == _Layer.all ? _Layer.db : _layer,
              ));
            });
            _scrollBottom();
            return;
          }

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

          final fus = serverChips ??
              (isNoMatch
                  ? <String>[]
                  : _layer != _Layer.all
                      ? _filterChips(List<String>.from(_kFollowUps[_layer] ?? []))
                      : _filterChips(List<String>.from(_kIntentFollowUps[intent] ?? [])));

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
    // Top-level FAQ category menu
    final categoryQs = _kFaqCategories[input];
    if (categoryQs != null) {
      return _Msg(
        text: 'Here are our FAQs on $input — tap one to see the answer:',
        isBot: true,
        layer: _Layer.staticInfo,
        chips: [...categoryQs, '← Back'],
      );
    }

    // Check static FAQ map — show a few sibling questions from the same category as follow-ups
    final staticAnswer = _kStaticQALocal[input];
    if (staticAnswer != null) {
      final category = _kFaqCategories.entries
          .firstWhere((e) => e.value.contains(input), orElse: () => _kFaqCategories.entries.first)
          .key;
      final siblings = _kFaqCategories[category]!.where((q) => q != input).take(3).toList();
      return _Msg(
        text: staticAnswer,
        isBot: true,
        layer: _Layer.staticInfo,
        chips: [...siblings, '← Back'],
      );
    }

    switch (input) {
      case 'When will my report be ready?':
        return const _Msg(
          text: '⏱ Typical report turnaround times:\n\n'
              '• Routine tests (CBC, Blood Sugar) — Same day / within 24 hrs\n'
              '• Thyroid, LFT, KFT — 24 hrs\n'
              '• HbA1c, Vitamins — 24–48 hrs\n'
              '• Molecular Biology, Cytogenetics — 48–72 hrs\n\n'
              'You will receive an SMS once your report is ready.',
          isBot: true, layer: _Layer.staticInfo,
          chips: ['How do I download my report?', 'My booking', 'Contact support'],
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
          chips: ['When will my report be ready?', 'My booking', 'Contact support'],
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
          chips: ['My booking', 'Show all available tests', '← Back'],
        );
      // ── About Lab local answers ───────────────────────────────────────────
      case 'What is Microbiological Laboratory (MBL)?':
        return const _Msg(
          text: '🏥 About Microbiological Laboratory (MBL):\n\n'
              'MBL is a leading diagnostic laboratory committed to delivering accurate, '
              'timely, and reliable test results. We serve patients, clinics, and hospitals '
              'with a wide range of diagnostic services.\n\n'
              '📍 Main centres in Coimbatore & Trichy\n'
              '🔬 Departments: Molecular Biology, Cytogenetics, Serology, Microbiology, Biochemistry\n'
              '📞 Contact: 0422 4354242 | microlabindia.com',
          isBot: true, layer: _Layer.web,
          chips: ['What diagnostic services does MicroLab offer?', "What are MicroLab's accreditations?", 'Contact support'],
        );
      case 'What diagnostic services does MicroLab offer?':
        return const _Msg(
          text: '🧪 MicroLab Diagnostic Departments:\n\n'
              '• 🔬 Molecular Biology — DNA/RNA diagnostics, disease monitoring\n'
              '• 🧬 Cytogenetics — Chromosomal analysis for genetic & oncological disorders\n'
              '• 🩸 Serology — Antigen & antibody testing (infectious/autoimmune diseases)\n'
              '• 🦠 Microbiology — Culture, sensitivity & pathogen identification\n'
              '• ⚗️ Biochemistry — Metabolic panels, organ function tests\n'
              '• 🩺 Clinical Pathology — CBC, urinalysis, haematology\n\n'
              'All tests performed with modern instruments and strict quality control.',
          isBot: true, layer: _Layer.web,
          chips: ['Tell me about the Molecular Biology services', 'Tell me about the Cytogenetics department', "What are MicroLab's accreditations?"],
        );
      case 'Tell me about the Molecular Biology services':
        return const _Msg(
          text: '🔬 Molecular Biology at MicroLab:\n\n'
              'Our Molecular Biology Department provides high-precision DNA and RNA-based diagnostics for:\n\n'
              '• Infectious disease detection (TB, Hepatitis, HIV viral load)\n'
              '• Cancer gene profiling & disease monitoring\n'
              '• Genetic disorder screening\n'
              '• RT-PCR and Next-Generation Sequencing (NGS)\n\n'
              'Results are processed with validated techniques and strict quality control.',
          isBot: true, layer: _Layer.web,
          chips: ['Tell me about the Cytogenetics department', 'What diagnostic services does MicroLab offer?', "What are MicroLab's accreditations?"],
        );
      case 'Tell me about the Cytogenetics department':
        return const _Msg(
          text: '🧬 Cytogenetics at MicroLab:\n\n'
              'Our Cytogenetics lab specialises in chromosomal analysis for:\n\n'
              '• Genetic disorders (Down syndrome, Turner syndrome)\n'
              '• Oncology — chromosomal changes in cancer cells\n'
              '• Prenatal diagnosis\n'
              '• Infertility & recurrent pregnancy loss evaluation\n\n'
              'Tests include Karyotyping, FISH, and Microarray analysis.',
          isBot: true, layer: _Layer.web,
          chips: ['Tell me about the Molecular Biology services', 'What diagnostic services does MicroLab offer?', 'Contact support'],
        );
      case "What are MicroLab's accreditations?":
        return const _Msg(
          text: '✅ Quality & Accreditations:\n\n'
              'Microbiological Laboratory (MBL) is committed to:\n\n'
              '• Accuracy & Precision — validated protocols and modern instruments\n'
              '• Transparency & Ethics — complete integrity in testing and reporting\n'
              '• Innovation — continuous adoption of new diagnostic technologies\n'
              '• Patient Safety — strict biosafety and quality control at every step\n\n'
              'For full accreditation details, visit microlabindia.com.',
          isBot: true, layer: _Layer.web,
          chips: ['What diagnostic services does MicroLab offer?', 'Contact support'],
        );
      case 'Who are the doctors at MicroLab?':
        return const _Msg(
          text: '👨‍⚕️ Medical Team:\n\n'
              'MicroLab is staffed by experienced pathologists, microbiologists, and '
              'lab specialists trained in the latest diagnostic techniques.\n\n'
              'For details about our medical team or to speak with a specialist:\n'
              '📞 0422 4354242 / 4354212\n'
              '🌐 microlabindia.com\n'
              '📧 microlabcbe@microlabindia.com',
          isBot: true, layer: _Layer.web,
          chips: ['What diagnostic services does MicroLab offer?', 'Contact support'],
        );
      case 'How can I access my reports online?':
        return const _Msg(
          text: '📱 Accessing Your Report Online:\n\n'
              '1. Visit microlabindia.com → Patient Portal\n'
              '2. Log in with your patient credentials\n'
              '3. Select your test from the dashboard\n'
              '4. Tap "Download Report" to save as PDF\n\n'
              '💬 You also receive an SMS notification when the report is ready.',
          isBot: true, layer: _Layer.web,
          chips: ['When will my report be ready?', 'My booking', 'Contact support'],
        );
      case 'What is the home sample collection process?':
      case 'How do I book a home collection?':
        return const _Msg(
          text: '🏠 Home Sample Collection:\n\n'
              '1. Book online at microlabindia.com or call 0422 4354242\n'
              '2. Choose your preferred date & time slot\n'
              '3. A trained phlebotomist arrives at your doorstep\n'
              '4. Sample is collected safely and hygienically\n'
              '5. Sent to the lab for processing\n'
              '6. Report available on the patient portal with SMS alert\n\n'
              '📞 Home collection charges may apply — call to confirm.',
          isBot: true, layer: _Layer.web,
          chips: ['Can I track my home collection technician?', 'When will my report be ready?', 'Contact support'],
        );
      case '← Back':
        return _Msg(text: 'Sure! What else can I help you with?', isBot: true, layer: _Layer.all, chips: _kFaqCategoryNames);
      default:
        return _Msg(text: "I didn't quite get that. Please choose an option or type your question.", isBot: true, layer: _Layer.all, chips: _kFaqCategoryNames);
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        children: [
          if (_kShowYoutubePromo) ...const [
            _YoutubeCard(),
            SizedBox(height: 10),
          ],
          const _BannerCarousel(imageUrls: _kBannerUrls),
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
                      setState(() {
                        // Remove the form from chat — replace with a compact confirmation.
                        final idx = _msgs.indexWhere(
                            (m) => m.kind == _MsgKind.bookingForm);
                        if (idx != -1) {
                          _msgs[idx] = const _Msg(
                            text: '✓ Booking submitted successfully.',
                            isBot: true,
                            layer: _Layer.book,
                          );
                        }
                        _msgs.add(const _Msg(
                          text: 'What would you like to do next? Switch to a layer:',
                          isBot: true,
                          layer: _Layer.book,
                          kind: _MsgKind.layerSuggestion,
                        ));
                      });
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
                  child: _linkifyText(msg.text,
                      const TextStyle(fontSize: 13, height: 1.65, color: AppColors.textPrimary)),
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
                                  chips: _kLayerQs[l]?.take(5).toList(),
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

  static final RegExp _urlPattern = RegExp(r'(https?://\S+)');

  // Renders text with any http(s) URL (e.g. a test report link) as a tappable, underlined
  // link that opens in the device's browser. Falls back to a plain Text when there's no
  // URL, so this is safe to use everywhere a bot bubble renders msg.text.
  Widget _linkifyText(String text, TextStyle style) {
    final matches = _urlPattern.allMatches(text).toList();
    if (matches.isEmpty) return Text(text, style: style);

    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in matches) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final url = m.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: style.copyWith(color: AppColors.brandGreen, decoration: TextDecoration.underline),
        recognizer: TapGestureRecognizer()
          ..onTap = () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));

    return Text.rich(TextSpan(style: style, children: spans));
  }

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
                  child: _linkifyText(msg.text,
                      const TextStyle(fontSize: 13, height: 1.65, color: AppColors.textPrimary)),
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
        _item(_Layer.staticInfo, 'Help & FAQ'),
        _item(_Layer.db,         'Tests & Prices'),
        _item(_Layer.web,        'About Lab'),
        _item(_Layer.book,       'Book Test'),
      ],
    );
  }

  PopupMenuItem<_Layer> _item(_Layer l, String label) {
    return PopupMenuItem(
      value: l,
      child: Text(label, style: const TextStyle(
          fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
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
          color: AppColors.brandGreenSurface,
          border: Border.all(color: AppColors.brandGreenLight, width: 1.5),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          layer.label,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.brandGreen),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          textAlign: TextAlign.center,
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
  bool    _loading = false;
  bool    _success = false;
  String? _error;

  // Optional — a booking can be submitted with no document attached at all.
  PlatformFile? _pickedFile;
  bool _picking = false;

  @override
  void dispose() {
    _name.dispose(); _age.dispose(); _phone.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'],
        withData: true, // ensures .bytes is populated on every platform, incl. web
      );
      if (result != null && result.files.isNotEmpty && mounted) {
        setState(() => _pickedFile = result.files.single);
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open file picker. Please try again.');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _submit() async {
    final name  = _name.text.trim();
    final age   = _age.text.trim();
    final phone = _phone.text.trim();

    if (name.isEmpty || age.isEmpty || phone.isEmpty) {
      setState(() => _error = 'Please fill in all fields.');
      return;
    }
    if (!RegExp(r'^\d{7,15}$').hasMatch(phone)) {
      setState(() => _error = 'Enter a valid phone number (7–15 digits).');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final req = http.MultipartRequest(
          'POST', Uri.parse('${widget.apiBase}/api/chat/book-test'))
        ..fields['name']  = name
        ..fields['age']   = age
        ..fields['phone'] = phone;

      final file = _pickedFile;
      if (file != null && file.bytes != null) {
        req.files.add(http.MultipartFile.fromBytes(
          'document', file.bytes!,
          filename: file.name,
        ));
      }

      final streamedRes = await req.send().timeout(const Duration(seconds: 20));
      final res = await http.Response.fromStream(streamedRes);
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
                'Booking confirmed for ${_name.text.trim()}.\nOur team will reach you shortly.',
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
        const Text('Upload Document (optional)',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
        const SizedBox(height: 4),
        _pickedFile == null
            ? OutlinedButton.icon(
                onPressed: _picking ? null : _pickFile,
                icon: _picking
                    ? const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen))
                    : const Icon(Icons.attach_file_rounded, size: 16, color: AppColors.brandGreen),
                label: const Text('Attach image or PDF',
                    style: TextStyle(fontSize: 12.5, color: AppColors.brandGreen, fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.divider, width: 1.5),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                  minimumSize: const Size(double.infinity, 0),
                  alignment: Alignment.centerLeft,
                ),
              )
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: AppColors.divider, width: 1.5),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.insert_drive_file_rounded, size: 16, color: AppColors.brandGreen),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_pickedFile!.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, color: AppColors.textPrimary)),
                    ),
                    InkWell(
                      onTap: () => setState(() => _pickedFile = null),
                      child: const Icon(Icons.close_rounded, size: 16, color: AppColors.textSecondary),
                    ),
                  ],
                ),
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
            Flexible(child: Text('Verified! Fetching your details…',
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
