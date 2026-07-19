import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class JbdDeviceConfig {
  final String name;
  final String mac;

  const JbdDeviceConfig({required this.name, required this.mac});

  Map<String, dynamic> toJson() => {'name': name, 'mac': mac};

  factory JbdDeviceConfig.fromJson(Map<String, dynamic> j) =>
      JbdDeviceConfig(name: j['name'] as String, mac: j['mac'] as String);
}

class AppConfig {
  static const _kOnboardingDone = 'app_config_onboarding_done_v1';
  static const _kDevicesMeta   = 'app_config_devices_meta_jbd_v1';
  static const _kBatteryCapacity = 'app_config_battery_capacity_ah';
  static const _kBatteryType    = 'app_config_battery_type';
  static const _kSocWarn        = 'app_config_soc_warn';
  static const _kSocCritical    = 'app_config_soc_critical';
  static const _kSocEmergency   = 'app_config_soc_emergency';
  static const _kInverterIdle   = 'app_config_inverter_idle_amps';
  static const _kHighLoadW      = 'app_config_high_load_watts';
  static const _kHighLoadMinutes = 'app_config_high_load_minutes';

  final List<JbdDeviceConfig> devices;
  final double batteryCapacityAh;
  final String batteryType;
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
    required this.socWarn,
    required this.socCritical,
    required this.socEmergency,
    required this.inverterIdleAmps,
    required this.highLoadWattsThreshold,
    required this.highLoadMinutes,
  });

  bool get isConfigured => devices.isNotEmpty;

  static AppConfig defaults() => const AppConfig(
        devices: [],
        batteryCapacityAh: 100.0,
        batteryType: 'LiFePO4',
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

    final devices = <JbdDeviceConfig>[];
    final raw = prefs.getString(_kDevicesMeta);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          devices.add(JbdDeviceConfig.fromJson((item as Map).cast<String, dynamic>()));
        }
      } catch (_) {}
    }

    return AppConfig(
      devices: devices,
      batteryCapacityAh: prefs.getDouble(_kBatteryCapacity) ?? d.batteryCapacityAh,
      batteryType: prefs.getString(_kBatteryType) ?? d.batteryType,
      socWarn: prefs.getDouble(_kSocWarn) ?? d.socWarn,
      socCritical: prefs.getDouble(_kSocCritical) ?? d.socCritical,
      socEmergency: prefs.getDouble(_kSocEmergency) ?? d.socEmergency,
      inverterIdleAmps: prefs.getDouble(_kInverterIdle) ?? d.inverterIdleAmps,
      highLoadWattsThreshold: prefs.getDouble(_kHighLoadW) ?? d.highLoadWattsThreshold,
      highLoadMinutes: prefs.getInt(_kHighLoadMinutes) ?? d.highLoadMinutes,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDevicesMeta, jsonEncode(devices.map((d) => d.toJson()).toList()));
    await prefs.setDouble(_kBatteryCapacity, batteryCapacityAh);
    await prefs.setString(_kBatteryType, batteryType);
    await prefs.setDouble(_kSocWarn, socWarn);
    await prefs.setDouble(_kSocCritical, socCritical);
    await prefs.setDouble(_kSocEmergency, socEmergency);
    await prefs.setDouble(_kInverterIdle, inverterIdleAmps);
    await prefs.setDouble(_kHighLoadW, highLoadWattsThreshold);
    await prefs.setInt(_kHighLoadMinutes, highLoadMinutes);
  }

  static Future<bool> isOnboardingDone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kOnboardingDone) ?? false;
  }

  static Future<void> markOnboardingDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnboardingDone, true);
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in [
      _kOnboardingDone, _kDevicesMeta, _kBatteryCapacity, _kBatteryType,
      _kSocWarn, _kSocCritical, _kSocEmergency, _kInverterIdle,
      _kHighLoadW, _kHighLoadMinutes,
    ]) {
      await prefs.remove(k);
    }
  }

  AppConfig copyWith({
    List<JbdDeviceConfig>? devices,
    double? batteryCapacityAh,
    String? batteryType,
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
        socWarn: socWarn ?? this.socWarn,
        socCritical: socCritical ?? this.socCritical,
        socEmergency: socEmergency ?? this.socEmergency,
        inverterIdleAmps: inverterIdleAmps ?? this.inverterIdleAmps,
        highLoadWattsThreshold: highLoadWattsThreshold ?? this.highLoadWattsThreshold,
        highLoadMinutes: highLoadMinutes ?? this.highLoadMinutes,
      );
}
