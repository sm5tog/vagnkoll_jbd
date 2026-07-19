import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Konfiguration för en enskild Victron-enhet. Encryption-keyn lagras
/// separat i flutter_secure_storage; resten ligger i JSON i SharedPreferences.
class VictronDeviceConfig {
  final String name;
  final String mac;            // ex 'F2:9D:4C:1A:BE:92'
  final String encryptionKey;  // 32 hex tecken
  final String kind;           // 'shunt' eller 'solar'

  const VictronDeviceConfig({
    required this.name,
    required this.mac,
    required this.encryptionKey,
    required this.kind,
  });

  Map<String, dynamic> toMetaJson() => {
        'name': name,
        'mac': mac,
        'kind': kind,
      };

  factory VictronDeviceConfig.fromMetaJson(
    Map<String, dynamic> json,
    String encryptionKey,
  ) {
    return VictronDeviceConfig(
      name: json['name'] as String,
      mac: json['mac'] as String,
      kind: json['kind'] as String,
      encryptionKey: encryptionKey,
    );
  }

  VictronDeviceConfig copyWith({
    String? name,
    String? mac,
    String? encryptionKey,
    String? kind,
  }) =>
      VictronDeviceConfig(
        name: name ?? this.name,
        mac: mac ?? this.mac,
        encryptionKey: encryptionKey ?? this.encryptionKey,
        kind: kind ?? this.kind,
      );
}

/// All användarkonfigurerbar inställning samlad i ett objekt. Ersätter
/// `secrets.dart` när setup-skärmen är färdig (blocker #1 i BESLUT.md).
///
/// Lagring:
///   - encryption keys → flutter_secure_storage (Android KeyStore)
///   - allt annat → SharedPreferences
///
/// Se "Encryption key-lagring efter setup-skärmen" i BESLUT.md för motivering.
class AppConfig {
  // SharedPreferences-nycklar
  static const _kOnboardingDone = 'app_config_onboarding_done_v1';
  static const _kDevicesMeta = 'app_config_devices_meta_v1';
  static const _kBatteryCapacity = 'app_config_battery_capacity_ah';
  static const _kBatteryType = 'app_config_battery_type';
  static const _kSolarMaxW = 'app_config_solar_max_w';
  static const _kSocWarn = 'app_config_soc_warn';
  static const _kSocCritical = 'app_config_soc_critical';
  static const _kSocEmergency = 'app_config_soc_emergency';
  static const _kInverterIdle = 'app_config_inverter_idle_amps';
  static const _kHighLoadW = 'app_config_high_load_watts';
  static const _kHighLoadMinutes = 'app_config_high_load_minutes';

  // Secure storage-nyckelprefix (en post per device-MAC)
  static const _kSecureKeyPrefix = 'victron_key_';

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final List<VictronDeviceConfig> devices;
  final double batteryCapacityAh;
  final String batteryType;
  final double solarMaxW;
  final double socWarn;
  final double socCritical;
  final double socEmergency;
  final double inverterIdleAmps;
  final double highLoadWattsThreshold;
  final int highLoadMinutes;

  const AppConfig({
    required this.devices,
    required this.batteryCapacityAh,
    required this.batteryType,
    required this.solarMaxW,
    required this.socWarn,
    required this.socCritical,
    required this.socEmergency,
    required this.inverterIdleAmps,
    required this.highLoadWattsThreshold,
    required this.highLoadMinutes,
  });

  /// True om setup är gjord (minst en device med encryption key sparad).
  bool get isConfigured => devices.any((d) => d.encryptionKey.isNotEmpty);

  /// Default-värden för en helt ny installation. Användaren får överskugga
  /// dessa i setup-skärmen.
  static AppConfig defaults() => const AppConfig(
        devices: [],
        batteryCapacityAh: 100.0,
        batteryType: 'LiFePO4',
        solarMaxW: 100.0,
        socWarn: 30.0,
        socCritical: 20.0,
        socEmergency: 15.0,
        inverterIdleAmps: 0.5,
        highLoadWattsThreshold: 72.0,
        highLoadMinutes: 10,
      );

  static Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final d = defaults();

    final devices = <VictronDeviceConfig>[];
    final raw = prefs.getString(_kDevicesMeta);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          final map = (item as Map).cast<String, dynamic>();
          final mac = map['mac'] as String;
          // Secure storage-läsning i separat try-catch: om den misslyckas
          // (EMUI-kompatibilitetsfel, KeyStore ej redo) inkludera enheten
          // utan nyckel — MAC:en räcker för withRemoteIds BLE-filter.
          String key = '';
          try {
            key = await _secure.read(key: '$_kSecureKeyPrefix$mac') ?? '';
          } catch (_) {}
          devices.add(VictronDeviceConfig.fromMetaJson(map, key));
        }
      } catch (_) {
        // Korrupt JSON — behandla som tomt
      }
    }

    return AppConfig(
      devices: devices,
      batteryCapacityAh:
          prefs.getDouble(_kBatteryCapacity) ?? d.batteryCapacityAh,
      batteryType: prefs.getString(_kBatteryType) ?? d.batteryType,
      solarMaxW: prefs.getDouble(_kSolarMaxW) ?? d.solarMaxW,
      socWarn: prefs.getDouble(_kSocWarn) ?? d.socWarn,
      socCritical: prefs.getDouble(_kSocCritical) ?? d.socCritical,
      socEmergency: prefs.getDouble(_kSocEmergency) ?? d.socEmergency,
      inverterIdleAmps:
          prefs.getDouble(_kInverterIdle) ?? d.inverterIdleAmps,
      highLoadWattsThreshold:
          prefs.getDouble(_kHighLoadW) ?? d.highLoadWattsThreshold,
      highLoadMinutes:
          prefs.getInt(_kHighLoadMinutes) ?? d.highLoadMinutes,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();

    final meta = devices.map((dev) => dev.toMetaJson()).toList();
    await prefs.setString(_kDevicesMeta, jsonEncode(meta));

    // Hela secure-storan synkas mot devices: skriv över keys för aktuella
    // MAC:ar, ta bort eventuella keys som inte längre används.
    final macsKvar = devices.map((d) => d.mac).toSet();
    final allKeys = await _secure.readAll();
    for (final k in allKeys.keys) {
      if (k.startsWith(_kSecureKeyPrefix)) {
        final mac = k.substring(_kSecureKeyPrefix.length);
        if (!macsKvar.contains(mac)) {
          await _secure.delete(key: k);
        }
      }
    }
    for (final dev in devices) {
      await _secure.write(
        key: '$_kSecureKeyPrefix${dev.mac}',
        value: dev.encryptionKey,
      );
    }

    await prefs.setDouble(_kBatteryCapacity, batteryCapacityAh);
    await prefs.setString(_kBatteryType, batteryType);
    await prefs.setDouble(_kSolarMaxW, solarMaxW);
    await prefs.setDouble(_kSocWarn, socWarn);
    await prefs.setDouble(_kSocCritical, socCritical);
    await prefs.setDouble(_kSocEmergency, socEmergency);
    await prefs.setDouble(_kInverterIdle, inverterIdleAmps);
    await prefs.setDouble(_kHighLoadW, highLoadWattsThreshold);
    await prefs.setInt(_kHighLoadMinutes, highLoadMinutes);
  }

  /// True om användaren antingen sparat konfig eller tryckt "hoppa över"
  /// i onboarding. Används av main för att avgöra om setup-skärmen ska
  /// triggas vid första start.
  static Future<bool> isOnboardingDone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kOnboardingDone) ?? false;
  }

  static Future<void> markOnboardingDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnboardingDone, true);
  }

  /// Radera all konfig och alla secure keys. Används av "Återställ
  /// fabriksinställningar" i setup-skärmen.
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kOnboardingDone);
    await prefs.remove(_kDevicesMeta);
    await prefs.remove(_kBatteryCapacity);
    await prefs.remove(_kBatteryType);
    await prefs.remove(_kSolarMaxW);
    await prefs.remove(_kSocWarn);
    await prefs.remove(_kSocCritical);
    await prefs.remove(_kSocEmergency);
    await prefs.remove(_kInverterIdle);
    await prefs.remove(_kHighLoadW);
    await prefs.remove(_kHighLoadMinutes);

    final allKeys = await _secure.readAll();
    for (final k in allKeys.keys) {
      if (k.startsWith(_kSecureKeyPrefix)) {
        await _secure.delete(key: k);
      }
    }
  }

  AppConfig copyWith({
    List<VictronDeviceConfig>? devices,
    double? batteryCapacityAh,
    String? batteryType,
    double? solarMaxW,
    double? socWarn,
    double? socCritical,
    double? socEmergency,
    double? inverterIdleAmps,
    double? highLoadWattsThreshold,
    int? highLoadMinutes,
  }) =>
      AppConfig(
        devices: devices ?? this.devices,
        batteryCapacityAh: batteryCapacityAh ?? this.batteryCapacityAh,
        batteryType: batteryType ?? this.batteryType,
        solarMaxW: solarMaxW ?? this.solarMaxW,
        socWarn: socWarn ?? this.socWarn,
        socCritical: socCritical ?? this.socCritical,
        socEmergency: socEmergency ?? this.socEmergency,
        inverterIdleAmps: inverterIdleAmps ?? this.inverterIdleAmps,
        highLoadWattsThreshold:
            highLoadWattsThreshold ?? this.highLoadWattsThreshold,
        highLoadMinutes: highLoadMinutes ?? this.highLoadMinutes,
      );
}
