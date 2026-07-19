import 'dart:async';

import '../appliances/appliance_store.dart';
import '../appliances/classifier.dart';
import '../config/app_config.dart';
import '../jbd/jbd_bms_scanner.dart';
import '../victron/victron_scanner.dart';

enum AlarmLevel { info, warn, critical, emergency }

class Alarm {
  final String id;          // unik id per regel
  final String message;
  final AlarmLevel level;
  final DateTime since;
  final bool isFriendly;    // glädje-meddelande, inte ett larm
  Alarm({
    required this.id,
    required this.message,
    required this.level,
    required this.since,
    this.isFriendly = false,
  });
}

class AlarmEngine {
  final _alarms = <String, Alarm>{};
  final _controller = StreamController<List<Alarm>>.broadcast();
  Stream<List<Alarm>> get stream => _controller.stream;
  List<Alarm> get current => _alarms.values.toList();

  // Larmtrösklar — uppdateras via updateConfig() när användaren sparar setup
  double _socWarn = 30.0;
  double _socCritical = 20.0;
  double _socEmergency = 15.0;
  double _inverterIdleAmps = 0.5;
  double _highLoadWattsThreshold = 72.0;
  int _highLoadMinutes = 10;

  void updateConfig(AppConfig cfg) {
    _socWarn = cfg.socWarn;
    _socCritical = cfg.socCritical;
    _socEmergency = cfg.socEmergency;
    _inverterIdleAmps = cfg.inverterIdleAmps;
    _highLoadWattsThreshold = cfg.highLoadWattsThreshold;
    _highLoadMinutes = cfg.highLoadMinutes;
  }

  // Tid en orsak måste hålla i sig innan vi larmar
  static const _inverterIdleDelay = Duration(minutes: 5);
  DateTime? _inverterFirstSeen;
  DateTime? _highLoadFirstSeen;

  StreamSubscription<VictronState>? _vSub;
  StreamSubscription<ClassificationResult>? _cSub;
  VictronState? _lastState;

  void attach({
    required JbdBmsScanner scanner,
    required Classifier classifier,
  }) {
    _vSub = scanner.stream.listen((s) {
      _lastState = s;
      _evaluate();
    });
    _cSub = classifier.stream.listen((_) => _evaluate());
  }

  void _evaluate() {
    final s = _lastState;
    if (s == null) return;

    _evaluateSoc(s);
    _evaluateInverterIdle(s);
    _evaluateHighLoad(s);
    _evaluateWarnAppliances();

    _controller.add(current);
  }

  void _evaluateHighLoad(VictronState s) {
    final voltage = s.shunt?.batteryVoltage ?? s.solar?.batteryVoltage;
    if (voltage == null || voltage <= 0) return;
    final loadA = (s.solar?.pvPower ?? 0.0) / voltage - (s.shunt?.current ?? 0.0);
    final loadW = loadA * voltage;
    if (loadW >= _highLoadWattsThreshold) {
      _highLoadFirstSeen ??= DateTime.now();
      final elapsed = DateTime.now().difference(_highLoadFirstSeen!);
      if (elapsed.inMinutes >= _highLoadMinutes) {
        _set(Alarm(
          id: 'high_load',
          message:
              'Hög förbrukning: ${loadW.toStringAsFixed(0)} W i ${elapsed.inMinutes} min — vad är på?',
          level: AlarmLevel.warn,
          since: _highLoadFirstSeen!,
        ));
      }
    } else {
      _highLoadFirstSeen = null;
      _clear('high_load');
    }
  }

  void _evaluateSoc(VictronState s) {
    final soc = s.shunt?.soc;
    if (soc == null || soc.isNaN) {
      _clear('soc');
      return;
    }
    if (soc < _socEmergency) {
      _set(Alarm(
        id: 'soc',
        message: 'Kritiskt: batteri $soc % — STÄNG AV ALLT',
        level: AlarmLevel.emergency,
        since: _alarms['soc']?.since ?? DateTime.now(),
      ));
    } else if (soc < _socCritical) {
      _set(Alarm(
        id: 'soc',
        message: 'Batterinivå kritiskt låg: ${soc.toStringAsFixed(1)} %',
        level: AlarmLevel.critical,
        since: _alarms['soc']?.since ?? DateTime.now(),
      ));
    } else if (soc < _socWarn) {
      _set(Alarm(
        id: 'soc',
        message: 'Batterinivå låg: ${soc.toStringAsFixed(1)} %',
        level: AlarmLevel.warn,
        since: _alarms['soc']?.since ?? DateTime.now(),
      ));
    } else {
      _clear('soc');
    }
  }

  void _evaluateInverterIdle(VictronState s) {
    final current = s.shunt?.current;
    if (current == null || current.isNaN) return;

    // Heuristik: om förbrukningen ligger nära invertertomgång (±0.3 A) men
    // inget annat verkar dra → invertern står på i onödan.
    // (Detta är en grov approximation — kan förfinas när mer data finns.)
    final inverterLikelyOn = current < 0 &&
        (current.abs() >= _inverterIdleAmps - 0.3) &&
        (current.abs() <= _inverterIdleAmps + 0.5);

    if (inverterLikelyOn) {
      _inverterFirstSeen ??= DateTime.now();
      if (DateTime.now().difference(_inverterFirstSeen!) >= _inverterIdleDelay) {
        _set(Alarm(
          id: 'inverter_idle',
          message: 'Invertern verkar stå på i tomgång — slå av om du inte använder den',
          level: AlarmLevel.warn,
          since: _inverterFirstSeen!,
        ));
      }
    } else {
      _inverterFirstSeen = null;
      _clear('inverter_idle');
    }
  }

  void _evaluateWarnAppliances() {
    // Hanteras av extern setter — se [updateActiveAppliances].
  }

  /// Anropas av huvudvyn när klassificeraren har nya resultat.
  void updateActiveAppliances(List<Appliance> active) {
    final activeIds = active.map((a) => 'app:${a.id}').toSet();

    // Ta bort larm för apparater som inte längre är aktiva
    final toRemove = _alarms.keys
        .where((k) => k.startsWith('app:') && !activeIds.contains(k))
        .toList();
    for (final k in toRemove) {
      _clear(k);
    }

    for (final a in active) {
      final id = 'app:${a.id}';
      switch (a.category) {
        case ApplianceCategory.warn:
          _set(Alarm(
            id: id,
            message: a.customMessage ?? '⚠️ ${a.name} verkar vara på',
            level: AlarmLevel.warn,
            since: _alarms[id]?.since ?? DateTime.now(),
          ));
          break;
        case ApplianceCategory.friendly:
          _set(Alarm(
            id: id,
            message: a.customMessage ?? 'Ska bli gott med ${a.name.toLowerCase()} :-)',
            level: AlarmLevel.info,
            since: _alarms[id]?.since ?? DateTime.now(),
            isFriendly: true,
          ));
          break;
        case ApplianceCategory.load:
          break;
      }
    }
    _controller.add(current);
  }

  void _set(Alarm a) {
    _alarms[a.id] = a;
  }

  void _clear(String id) {
    _alarms.remove(id);
  }

  void dispose() {
    _vSub?.cancel();
    _cSub?.cancel();
    _controller.close();
  }
}
