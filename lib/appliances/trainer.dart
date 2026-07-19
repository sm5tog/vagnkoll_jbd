import 'dart:async';

import '../jbd/jbd_bms_scanner.dart';
import '../victron/victron_scanner.dart';
import 'load_calculator.dart';

/// Snabb-mätning av en apparats effekt. Användaren slår på apparaten,
/// trycker "Mät", och appen tar genomsnitt över 5 sekunder.
class QuickMeasure {
  static const Duration measureDuration = Duration(seconds: 5);

  final _stateController = StreamController<QuickMeasureState>.broadcast();
  Stream<QuickMeasureState> get stream => _stateController.stream;

  StreamSubscription<VictronState>? _sub;
  Timer? _tick;
  final List<double> _samples = [];
  DateTime? _startedAt;
  bool _done = false;
  double _result = 0;

  QuickMeasureState get current => QuickMeasureState(
        elapsedSec: _startedAt == null
            ? 0
            : DateTime.now().difference(_startedAt!).inMilliseconds / 1000.0,
        sampleCount: _samples.length,
        currentValue: _samples.isEmpty ? 0 : _samples.last,
        done: _done,
        averageWatts: _result,
      );

  void start(JbdBmsScanner scanner) {
    stop();
    _samples.clear();
    _startedAt = DateTime.now();
    _done = false;
    _result = 0;
    _sub = scanner.stream.listen(_onState);
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _stateController.add(current);
      if (_startedAt != null &&
          DateTime.now().difference(_startedAt!) >= measureDuration) {
        _finish();
      }
    });
  }

  void _onState(VictronState s) {
    if (_done) return;
    final voltage = s.shunt?.batteryVoltage ?? s.solar?.batteryVoltage;
    final loadA = LoadCalculator.load(s);
    if (voltage == null || voltage <= 0 || loadA == null) return;
    _samples.add(loadA * voltage);
  }

  void _finish() {
    _done = true;
    _tick?.cancel();
    if (_samples.isNotEmpty) {
      _result = _samples.reduce((a, b) => a + b) / _samples.length;
    }
    _stateController.add(current);
  }

  void stop() {
    _sub?.cancel();
    _tick?.cancel();
    _startedAt = null;
  }

  void dispose() {
    stop();
    _stateController.close();
  }
}

class QuickMeasureState {
  final double elapsedSec;
  final int sampleCount;
  final double currentValue;
  final bool done;
  final double averageWatts;
  QuickMeasureState({
    required this.elapsedSec,
    required this.sampleCount,
    required this.currentValue,
    required this.done,
    required this.averageWatts,
  });
}
