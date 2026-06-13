import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';

/// Coloured status badge used on booking cards and detail sheets.
class BookingStatusBadge extends StatelessWidget {
  final String status;
  const BookingStatusBadge({super.key, required this.status});

  Color get _color {
    switch (status) {
      case 'Completed':   return AppColors.brandGreen;
      case 'Cancelled':   return const Color(0xFFD32F2F);
      case 'In Progress': return const Color(0xFF1565C0);
      default:            return const Color(0xFFE65100); // Technician Allocated
    }
  }

  IconData get _icon {
    switch (status) {
      case 'Completed':   return Icons.check_circle_outline;
      case 'Cancelled':   return Icons.cancel_outlined;
      case 'In Progress': return Icons.directions_run_rounded;
      default:            return Icons.person_pin_outlined;
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: _color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _color.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 14, color: _color),
            const SizedBox(width: 5),
            Text(status,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _color)),
          ],
        ),
      );
}
