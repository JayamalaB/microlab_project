import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';

/// Coloured status badge used on booking cards and detail sheets.
class BookingStatusBadge extends StatelessWidget {
  final String status;
  const BookingStatusBadge({super.key, required this.status});

  Color get _color {
    switch (status) {
      case 'Completed':   return AppColors.brandGreen;
      case 'Cancelled':   return AppColors.error;
      case 'In Progress': return AppColors.blue;
      default:            return AppColors.amber; // Technician Allocated
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
  Widget build(BuildContext context) => Semantics(
        label: 'Status: $status',
        child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: _color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 16, color: _color),
            const SizedBox(width: 5),
            Text(status,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _color)),
          ],
        ),
        ),
      );
}
