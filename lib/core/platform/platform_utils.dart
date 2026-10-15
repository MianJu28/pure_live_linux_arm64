import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

class PlatformUtils {
  PlatformUtils._();
  static bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static bool get isDesktopNotMac => (Platform.isWindows || Platform.isLinux) && !Platform.isMacOS;

  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  static bool isMobileWidth(BuildContext context) {
    return MediaQuery.of(context).size.width < 760;
  }

  static bool get isWindows => Platform.isWindows;
  static bool get isMacOS => Platform.isMacOS;
  static bool get isLinux => Platform.isLinux;
  static bool get isAndroid => Platform.isAndroid;
  static bool get isIOS => Platform.isIOS;

  /// Whether the running build targets 64-bit ARM.
  ///
  /// Linux publishes separate `x64` and `arm64` packages, so the in-app update
  /// and download lists must select the matching asset instead of assuming x64.
  static bool get isArm64 {
    final abi = Abi.current();
    return abi == Abi.linuxArm64 ||
        abi == Abi.androidArm64 ||
        abi == Abi.iosArm64 ||
        abi == Abi.macosArm64 ||
        abi == Abi.windowsArm64;
  }

  static T select<T>({required T desktop, required T mobile}) {
    return isDesktop ? desktop : mobile;
  }
}
