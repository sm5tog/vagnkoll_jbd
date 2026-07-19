import '../victron/victron_scanner.dart'; // VictronState

/// Räknar ut ström som faktiskt går till laster, dvs allt utöver det som
/// solpanelen ger.
///
///   last_A = sol_A − shunt_ström     (där shunt_ström > 0 = batteri laddas)
///
/// När shunt_ström är positiv (batteri laddas) lägre än solens bidrag → last
/// drar mellanskillnaden. När shunt_ström är negativ (batteri urladdas) drar
/// last solens bidrag + det som tas från batteriet.
class LoadCalculator {
  static double? load(VictronState s) {
    final voltage = s.shunt?.batteryVoltage ?? s.solar?.batteryVoltage;
    final current = s.shunt?.current;
    if (voltage == null || voltage.isNaN || voltage <= 0) return null;
    if (current == null || current.isNaN) return null;
    final solarW = s.solar?.pvPower ?? 0.0;
    final solarA = solarW.isNaN ? 0.0 : solarW / voltage;
    final load = solarA - current;
    return load < 0 ? 0 : load;
  }
}
