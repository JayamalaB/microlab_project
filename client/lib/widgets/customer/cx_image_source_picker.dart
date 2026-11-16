import 'package:flutter/material.dart';
import 'package:microlab/widgets/customer/cx_cards.dart';
import 'package:microlab/widgets/customer/cx_sheet.dart';
import 'package:microlab/theme/customer_theme.dart';

/// Which image source the customer picked. The caller keeps calling its own
/// image picker; this widget only shows the choice.
enum CxImageSource { camera, gallery }

/// Camera / Gallery choice sheet. Returns the choice, or null when dismissed.
Future<CxImageSource?> showCxImageSourcePicker(
  BuildContext context, {
  String title = 'Add a photo',
  String? subtitle,
}) {
  return showCxSheet<CxImageSource>(
    context: context,
    title: title,
    subtitle: subtitle,
    builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
      CxOptionCard(
        icon: Icons.photo_camera_outlined,
        title: 'Camera',
        subtitle: 'Take a photo now',
        onTap: () => Navigator.pop(ctx, CxImageSource.camera),
      ),
      const SizedBox(height: CxSpace.md),
      CxOptionCard(
        icon: Icons.photo_library_outlined,
        title: 'Gallery',
        subtitle: 'Choose from your photos',
        onTap: () => Navigator.pop(ctx, CxImageSource.gallery),
      ),
    ]),
  );
}
