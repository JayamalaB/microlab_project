import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';

// ─── Branch data (replace with GET /api/branches) ────────────────────────────

const _kBranches = [
  {
    'name': 'MicroLab – T Nagar',
    'address': '45, Pondy Bazaar, T Nagar, Chennai – 600017',
    'phone': '+91 44-2815-0001',
    'hours': 'Mon–Sat: 7:00 AM – 8:00 PM  ·  Sun: 8:00 AM – 2:00 PM',
  },
  {
    'name': 'MicroLab – Adyar',
    'address': '12, Gandhi Nagar, Adyar, Chennai – 600020',
    'phone': '+91 44-2491-0002',
    'hours': 'Mon–Sat: 7:30 AM – 7:30 PM  ·  Sun: 8:00 AM – 1:00 PM',
  },
  {
    'name': 'MicroLab – Anna Nagar',
    'address': '89, 2nd Avenue, Anna Nagar, Chennai – 600040',
    'phone': '+91 44-2628-0003',
    'hours': 'Mon–Sat: 7:00 AM – 8:00 PM  ·  Sun: Closed',
  },
];

// ─── Chatbot FAB ──────────────────────────────────────────────────────────────

class SupportChatbotButton extends StatelessWidget {
  const SupportChatbotButton({super.key});

  void _open(BuildContext context) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const _ChatbotSheet(),
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
              Text('',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Chat message model ───────────────────────────────────────────────────────

class _Msg {
  final String text;
  final bool isBot;
  final List<String>? chips;
  const _Msg({required this.text, required this.isBot, this.chips});
}

// ─── Chatbot bottom sheet ─────────────────────────────────────────────────────

class _ChatbotSheet extends StatefulWidget {
  const _ChatbotSheet();

  @override
  State<_ChatbotSheet> createState() => _ChatbotSheetState();
}

class _ChatbotSheetState extends State<_ChatbotSheet> {
  final List<_Msg> _msgs = [];
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _msgs.add(const _Msg(
      text: "Hi! I'm your MicroLab assistant 👋\nHow can I help you today?",
      isBot: true,
      chips: ['Branch Info', 'Test FAQs', 'Booking Help', 'Contact Us'],
    ));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send(String text) {
    setState(() => _msgs.add(_Msg(text: text, isBot: false)));
    _scrollBottom();

    Future.delayed(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      final reply = _botReply(text);
      setState(() => _msgs.add(reply));
      _scrollBottom();
    });
  }

  void _scrollBottom() {
    Future.delayed(const Duration(milliseconds: 80), () {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        );
      }
    });
  }

  _Msg _botReply(String input) {
    switch (input) {
      // ── Level 1 ──────────────────────────────────────────
      case 'Branch Info':
        return const _Msg(
          text: 'Which branch would you like info about?',
          isBot: true,
          chips: ['T Nagar', 'Adyar', 'Anna Nagar', '← Back'],
        );
      case 'Test FAQs':
        return const _Msg(
          text: 'What would you like to know about tests?',
          isBot: true,
          chips: ['Fasting needed?', 'Report timing?', 'How collection works?', '← Back'],
        );
      case 'Booking Help':
        return const _Msg(
          text: 'What do you need help with?',
          isBot: true,
          chips: ['Cancel booking?', 'Reschedule?', 'Payment issue?', '← Back'],
        );
      case 'Contact Us':
        return const _Msg(
          text: '📞 Toll-Free: 1800-XXX-XXXX\n\n'
              '📧 Email: support@microlab.in\n\n'
              '⏰ Mon – Sat, 8:00 AM – 8:00 PM',
          isBot: true,
          chips: ['Branch Info', '← Back'],
        );

      // ── Branch details ────────────────────────────────────
      case 'T Nagar':
      case 'Adyar':
      case 'Anna Nagar':
        final b = _kBranches.firstWhere(
          (br) => (br['name'] as String).contains(input),
          orElse: () => _kBranches[0],
        );
        return _Msg(
          text: '📍 ${b['name']}\n\n'
              'Address: ${b['address']}\n\n'
              '📞 ${b['phone']}\n\n'
              '🕐 ${b['hours']}',
          isBot: true,
          chips: ['Other Branch', 'Contact Us', '← Back'],
        );
      case 'Other Branch':
        return const _Msg(
          text: 'Choose a branch:',
          isBot: true,
          chips: ['T Nagar', 'Adyar', 'Anna Nagar', '← Back'],
        );

      // ── Test FAQs ─────────────────────────────────────────
      case 'Fasting needed?':
        return const _Msg(
          text: 'Fasting (8–12 hrs) is required for tests like HbA1c, Lipid Profile, and Blood Glucose.\n\n'
              'Tests like CBC, Thyroid, and Vitamin D can be done without fasting.\n\n'
              'Each test card in the app shows the fasting requirement.',
          isBot: true,
          chips: ['Report timing?', '← Back'],
        );
      case 'Report timing?':
        return const _Msg(
          text: '⏱ Typical report turnaround:\n\n'
              '• CBC, Blood Sugar — 24 hrs\n'
              '• Thyroid Profile — 24 hrs\n'
              '• HbA1c — 48 hrs\n'
              '• Vitamins & Hormones — 48–72 hrs\n\n'
              'You\'ll get an SMS + app notification when your report is ready.',
          isBot: true,
          chips: ['Fasting needed?', '← Back'],
        );
      case 'How collection works?':
        return const _Msg(
          text: '🏠 Home Collection:\n'
              '1. Book & choose a time slot\n'
              '2. Technician arrives at your door\n'
              '3. Sample collected & sent to lab\n'
              '4. Report shared in the app\n\n'
              '🏥 Lab Visit:\n'
              '1. Walk in or book a slot\n'
              '2. Collect token at reception\n'
              '3. Sample collected in our phlebotomy room',
          isBot: true,
          chips: ['← Back'],
        );

      // ── Booking help ──────────────────────────────────────
      case 'Cancel booking?':
        return const _Msg(
          text: 'To cancel a booking:\n\n'
              '1. Go to the "Bookings" tab\n'
              '2. Open the booking\n'
              '3. Tap "Cancel Booking"\n\n'
              'Refunds for online payments are processed within 5–7 business days.',
          isBot: true,
          chips: ['Reschedule?', '← Back'],
        );
      case 'Reschedule?':
        return const _Msg(
          text: 'To reschedule, cancel the existing booking and create a new one.\n\n'
              'For help, call 1800-XXX-XXXX.',
          isBot: true,
          chips: ['Contact Us', '← Back'],
        );
      case 'Payment issue?':
        return const _Msg(
          text: 'If payment was deducted but booking wasn\'t confirmed, email us at support@microlab.in with your booking ID and payment screenshot.\n\n'
              'We\'ll resolve it within 24 hours.',
          isBot: true,
          chips: ['Contact Us', '← Back'],
        );

      // ── Navigation ────────────────────────────────────────
      case '← Back':
        return const _Msg(
          text: 'Sure! What else can I help you with?',
          isBot: true,
          chips: ['Branch Info', 'Test FAQs', 'Booking Help', 'Contact Us'],
        );

      default:
        return const _Msg(
          text: "I didn't quite get that. Please choose an option below or call 1800-XXX-XXXX for live support.",
          isBot: true,
          chips: ['Branch Info', 'Test FAQs', 'Booking Help', 'Contact Us'],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.72 + bottom,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // ── Header ───────────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
            decoration: const BoxDecoration(
              color: AppColors.brandGreen,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.support_agent_rounded, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('MicroLab Support',
                          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                      Text('Typically replies instantly',
                          style: TextStyle(color: Colors.white70, fontSize: 11)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
              ],
            ),
          ),

          // ── Messages ─────────────────────────────────────
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              itemCount: _msgs.length,
              itemBuilder: (_, i) {
                final msg = _msgs[i];
                return _buildBubble(context, msg);
              },
            ),
          ),

          // ── Input ─────────────────────────────────────────
          Container(
            padding: EdgeInsets.fromLTRB(12, 10, 12, MediaQuery.of(context).padding.bottom + 10),
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
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Type a message…',
                      hintStyle: const TextStyle(fontSize: 14, color: AppColors.textHint),
                      filled: true,
                      fillColor: AppColors.background,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (v) {
                      if (v.trim().isNotEmpty) {
                        _send(v.trim());
                        _ctrl.clear();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    if (_ctrl.text.trim().isNotEmpty) {
                      _send(_ctrl.text.trim());
                      _ctrl.clear();
                    }
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      color: AppColors.brandGreen,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.send_rounded, color: Colors.white, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBubble(BuildContext context, _Msg msg) {
    final maxW = MediaQuery.of(context).size.width * 0.76;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: msg.isBot ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          Container(
            constraints: BoxConstraints(maxWidth: maxW),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: msg.isBot ? AppColors.brandGreenSurface : AppColors.brandGreen,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(14),
                topRight: const Radius.circular(14),
                bottomLeft: Radius.circular(msg.isBot ? 4 : 14),
                bottomRight: Radius.circular(msg.isBot ? 14 : 4),
              ),
            ),
            child: Text(
              msg.text,
              style: TextStyle(
                fontSize: 13,
                height: 1.55,
                color: msg.isBot ? AppColors.textPrimary : Colors.white,
              ),
            ),
          ),
          if (msg.isBot && msg.chips != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: msg.chips!.map((chip) => GestureDetector(
                onTap: () => _send(chip),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: AppColors.brandGreen, width: 1.5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(chip,
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.brandGreen,
                          fontWeight: FontWeight.w500)),
                ),
              )).toList(),
            ),
          ],
        ],
      ),
    );
  }
}
