// Web-only implementation. Conditionally imported via:
//   import 'yt_web_stub.dart' if (dart.library.html) 'yt_web_impl.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/widgets.dart';

final _registered = <String>{};

Widget buildYtWebPlayer(String videoId) {
  final viewId = 'yt-player-$videoId';
  if (_registered.add(viewId)) {
    ui_web.platformViewRegistry.registerViewFactory(viewId, (_) {
      return html.IFrameElement()
        ..src = 'https://www.youtube.com/embed/$videoId'
            '?autoplay=1&rel=0&modestbranding=1'
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allow =
            'autoplay; fullscreen; encrypted-media; picture-in-picture'
        ..allowFullscreen = true;
    });
  }
  return HtmlElementView(viewType: viewId);
}
