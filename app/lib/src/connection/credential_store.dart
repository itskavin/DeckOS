import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Android: encrypted preferences with a Keystore-protected master key. No plaintext
/// fallback if the vault is unavailable; do not erase legacy data until write succeeds.
class CredentialStore {
  static const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static Future<String?> read(String id) => storage.read(key: 'pc_$id');
  static Future<void> write(String id, String value) =>
      storage.write(key: 'pc_$id', value: value);
  static Future<void> delete(String id) => storage.delete(key: 'pc_$id');
}
