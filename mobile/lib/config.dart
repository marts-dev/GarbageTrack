/// Compile-time API configuration.
///
/// Override for a device/emulator with:
/// `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000`
class ApiConfig {
  static const baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );
}
