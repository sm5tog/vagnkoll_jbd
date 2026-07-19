import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

import 'jbd/jbd_bms_scanner.dart';
import 'victron/victron_scanner.dart';

/// Räknar Ah använt och laddat under dagen.
///
/// Vid varje ögonblick:
///   sol_A   = sol_W / batterispänning
///   last_A  = sol_A − shunt_ström    (shunt_ström positiv = ström in i batteri)
///
/// Integrerar över tid (med trapezmetoden) för att få Ah-totaler.
/// Återställs automatiskt vid midnatt. Persisteras så att totalerna överlever
/// app-omstart inom samma dygn.
class EnergyCounter {
  static const _kPrefKey = 'energy_counter_v1';

  double usedAhToday = 0.0;     // Förbrukning till laster
  double solarAhToday = 0.0;    // Generering från sol
  double netAhToday = 0.0;      // Netto in i batteriet (kan vara +/−)

  String? _dateKey;             // YYYY-MM-DD
  DateTime? _lastSampleTime;
  double? _lastCurrent;
  double? _lastSolarAmps;       // sol_W / V

  final _changeController = StreamController<EnergyCounter>.broadcast();
  Stream<EnergyCounter> get stream => _changeController.stream;

  StreamSubscription<VictronState>? _sub;
  Timer? _persistTimer;
  SharedPreferences? _prefs;
  bool _paused = false;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _restore();
  }

  void attachScanner(JbdBmsScanner scanner) {
    _sub?.cancel();
    _sub = scanner.stream.listen(_onState);
    _persistTimer?.cancel();
    _persistTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _persist(),
    );
  }

  void pause() => _paused = true;
  void resume() {
    _paused = false;
    _lastSampleTime = null; // Ny start så vi inte räknar paus-tiden
    _lastCurrent = null;
    _lastSolarAmps = null;
  }

  void _onState(VictronState s) {
    if (_paused) return;
    final shunt = s.shunt;
    final solar = s.solar;
    final voltage = shunt?.batteryVoltage ?? solar?.batteryVoltage;
    if (voltage == null || voltage.isNaN || voltage <= 0) return;

    final current = shunt?.current; // A (positiv = laddas in)
    final solarW = solar?.pvPower ?? 0.0;
    final solarAmps = solarW.isNaN ? 0.0 : solarW / voltage;
    if (current == null || current.isNaN) return;

    final now = DateTime.now();
    _ensureDay(now);

    if (_lastSampleTime != null &&
        _lastCurrent != null &&
        _lastSolarAmps != null) {
      final dt = now.difference(_lastSampleTime!).inMilliseconds / 1000.0;
      // Slå inte i taket om appen pausats länge (>5 min mellan samples)
      if (dt > 0 && dt < 300) {
        final dtHours = dt / 3600.0;
        // Trapezmetoden — medelvärde mellan föregående och nuvarande
        final avgCurrent = (_lastCurrent! + current) / 2;
        final avgSolar = (_lastSolarAmps! + solarAmps) / 2;
        final avgLoad = avgSolar - avgCurrent;

        netAhToday += avgCurrent * dtHours;
        solarAhToday += avgSolar * dtHours;
        if (avgLoad > 0) {
          usedAhToday += avgLoad * dtHours;
        }
        _changeController.add(this);
      }
    }

    _lastSampleTime = now;
    _lastCurrent = current;
    _lastSolarAmps = solarAmps;
  }

  void _ensureDay(DateTime now) {
    final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    if (_dateKey != today) {
      _dateKey = today;
      usedAhToday = 0.0;
      solarAhToday = 0.0;
      netAhToday = 0.0;
      _lastSampleTime = null;
      _lastCurrent = null;
      _lastSolarAmps = null;
      _persist();
    }
  }

  void _restore() {
    final raw = _prefs?.getString(_kPrefKey);
    if (raw == null) return;
    final parts = raw.split('|');
    if (parts.length < 4) return;
    _dateKey = parts[0];
    usedAhToday = double.tryParse(parts[1]) ?? 0.0;
    solarAhToday = double.tryParse(parts[2]) ?? 0.0;
    netAhToday = double.tryParse(parts[3]) ?? 0.0;
  }

  Future<void> _persist() async {
    if (_prefs == null || _dateKey == null) return;
    await _prefs!.setString(
      _kPrefKey,
      '$_dateKey|$usedAhToday|$solarAhToday|$netAhToday',
    );
  }

  void dispose() {
    _sub?.cancel();
    _persistTimer?.cancel();
    _persist();
    _changeController.close();
  }
}
