import 'package:permission_handler/permission_handler.dart';

class PermissionsService {
  /// Request microphone permission safely
  /// Returns true only if microphone can actually be used
  static Future<bool> requestMicrophone() async {
    var status = await Permission.microphone.status;

    // Already granted
    if (status.isGranted) {
      return true;
    }

    // Request permission
    status = await Permission.microphone.request();

    if (status.isGranted) {
      return true;
    }

    // If permanently denied → user must enable in settings
    if (status.isPermanentlyDenied) {
      await openAppSettings();
      return false;
    }

    // Any other case (denied, restricted, limited)
    return false;
  }
}