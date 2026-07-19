import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../jbd/jbd_bms_scanner.dart';
import '../victron/victron_scanner.dart';
import 'appliance_store.dart';
import 'load_calculator.dart';

class ClassificationResult {
  final double totalLoadWatts;
  final List<Appliance> activeAppliances;
  ClassificationResult({
    required this.totalLoadWatts,
    required this.activeAppliances,
  });
}

/// Tröskel-baserad klassificerare. Matchar total last (watt) mot apparaternas
/// förväntade effekter. Använder subset-matchning för att hitta bästa
/// kombination, stabilitetsfilter per apparat för att undvika brus.
class Classifier {
  static const String _prefsKey = 'classifier_active_v2';
  static const Duration _smoothWindow = Duration(seconds: 5);

  List<Appliance> _appliances = [];
  final _result = StreamController<ClassificationResult>.broadcast();
  Stream<ClassificationResult> get stream => _result.stream;
  ClassificationResult? _last;
  ClassificationResult? get last => _last;

  bool _paused = false;
  final List<MapEntry<DateTime, double>> _historyW = [];
  final Map<int, DateTime> _firstMatched = {};
  final Set<int> _activeIds = {};

  SharedPreferences? _prefs;
  StreamSubscription<VictronState>? _sub;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final stored = _prefs?.getString(_prefsKey);
    if (stored != null) {
      try {
        final list = jsonDecode(stored) as List;
        _activeIds.addAll(list.map((e) => e as int));
      } catch (_) {}
    }
  }

  void setLibrary(List<Appliance> appliances) {
    _appliances = appliances;
    final validIds = appliances.map((a) => a.id ?? -1).toSet();
    _activeIds.removeWhere((id) => !validIds.contains(id));
    _persist();
    _emit();
  }

  void pause() {
    _paused = true;
    _historyW.clear();
    _firstMatched.clear();
  }

  void resume() => _paused = false;

  void attachScanner(JbdBmsScanner scanner) {
    _sub?.cancel();
    _sub = scanner.stream.listen(_onState);
  }

  void _onState(VictronState s) {
    if (_paused) return;

    final voltage = s.shunt?.batteryVoltage ?? s.solar?.batteryVoltage;
    final loadA = LoadCalculator.load(s);
    if (voltage == null || voltage <= 0 || loadA == null) return;
    final loadW = loadA * voltage;

    final now = DateTime.now();
    _historyW.add(MapEntry(now, loadW));
    _historyW.removeWhere((e) => now.difference(e.key) > _smoothWindow);
    if (_historyW.isEmpty) return;

    // Utjämnad last
    final smoothed =
        _historyW.map((e) => e.value).reduce((a, b) => a + b) /
            _historyW.length;

    // Hitta bästa subset
    final candidates = _bestSubset(smoothed);
    final candidateIds = candidates.map((a) => a.id ?? -1).toSet();

    // Stabilitetsfilter per apparat
    _firstMatched.removeWhere((id, _) => !candidateIds.contains(id));
    final activeNow = <Appliance>[];
    bool changed = false;
    for (final a in candidates) {
      final id = a.id ?? -1;
      _firstMatched.putIfAbsent(id, () => now);
      final elapsed = now.difference(_firstMatched[id]!).inSeconds;
      if (elapsed >= a.minDurationSec) {
        activeNow.add(a);
        if (!_activeIds.contains(id)) {
          _activeIds.add(id);
          changed = true;
        }
      }
    }
    // Avaktivera de som inte längre matchar
    final removeIds = _activeIds.where((id) => !candidateIds.contains(id)).toList();
    for (final id in removeIds) {
      _activeIds.remove(id);
      changed = true;
    }

    if (changed) {
      _persist();
      _emit();
    } else {
      // Uppdatera ändå last-värdet
      _last = ClassificationResult(
        totalLoadWatts: smoothed,
        activeAppliances:
            _appliances.where((a) => _activeIds.contains(a.id)).toList(),
      );
    }
  }

  /// Provar alla delmängder och returnerar den vars summa ligger inom
  /// varje apparats individuella tolerans samtidigt som totalen ligger
  /// närmast den faktiska lasten.
  List<Appliance> _bestSubset(double loadW) {
    final n = _appliances.length;
    if (n == 0) return const [];
    if (n > 12) return _greedyFallback(loadW);
    final total = 1 << n;
    List<Appliance>? best;
    double bestDist = double.infinity;
    for (var mask = 0; mask < total; mask++) {
      double sum = 0;
      final subset = <Appliance>[];
      for (var i = 0; i < n; i++) {
        if ((mask >> i) & 1 == 1) {
          sum += _appliances[i].expectedWatts;
          subset.add(_appliances[i]);
        }
      }
      final dist = (sum - loadW).abs();
      // Måste vara inom apparaternas kombinerade tolerans
      final maxTol = subset.fold<double>(0, (s, a) => s + a.toleranceWatts);
      // Plus en grundtolerans för småfluktuationer
      final allowed = maxTol + 20;
      if (dist <= allowed && dist < bestDist) {
        bestDist = dist;
        best = subset;
      }
    }
    return best ?? const [];
  }

  List<Appliance> _greedyFallback(double loadW) {
    final sorted = [..._appliances]
      ..sort((a, b) => b.expectedWatts.compareTo(a.expectedWatts));
    final active = <Appliance>[];
    var remaining = loadW;
    for (final a in sorted) {
      if (remaining >= a.lowerBound) {
        active.add(a);
        remaining -= a.expectedWatts;
      }
    }
    return active;
  }

  void _persist() {
    _prefs?.setString(_prefsKey, jsonEncode(_activeIds.toList()));
  }

  void _emit() {
    final smoothed = _historyW.isEmpty
        ? 0.0
        : _historyW.map((e) => e.value).reduce((a, b) => a + b) /
            _historyW.length;
    final active =
        _appliances.where((a) => _activeIds.contains(a.id)).toList();
    final result = ClassificationResult(
      totalLoadWatts: smoothed,
      activeAppliances: active,
    );
    _last = result;
    _result.add(result);
  }

  void dispose() {
    _sub?.cancel();
    _result.close();
  }
}
