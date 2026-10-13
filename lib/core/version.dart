/// Single source of truth for the app version.
///
/// pubspec.yaml is the build-time authority (versionName/versionCode);
/// this constant mirrors it for display surfaces that cannot read pubspec
/// at runtime (settings page, MCP serverInfo). Bump both together.
const String appVersion = '1.5.24';
