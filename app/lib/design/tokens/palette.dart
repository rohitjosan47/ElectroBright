import 'package:flutter/painting.dart';

/// Base colours shared with the native launch screens
/// (ios/Runner/Assets.xcassets/LaunchBackground.colorset and
/// android/app/src/main/res/values*/colors.xml). Keep them identical so the
/// launch screen hands over to the first frame without a flash.
abstract final class Palette {
  static const Color canvasLight = Color(0xFFF2F3F7);
  static const Color canvasDark = Color(0xFF0A0C11);
}
