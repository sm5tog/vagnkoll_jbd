// Kopiera denna fil till lib/secrets.dart och fyll i dina egna värden.
// secrets.dart är .gitignore:ad så nycklarna hamnar aldrig på GitHub.

class VictronDevice {
  final String name;
  final String mac;
  final String encryptionKey;
  final String kind; // 'shunt' eller 'solar'

  const VictronDevice({
    required this.name,
    required this.mac,
    required this.encryptionKey,
    required this.kind,
  });
}

const List<VictronDevice> kVictronDevices = [
  VictronDevice(
    name: 'SmartShunt',
    mac: 'F2:9D:4C:1A:BE:92',
    encryptionKey: 'c6ea8b828f38adc30e17621c358cbe7b',
    kind: 'shunt',
  ),
  VictronDevice(
    name: 'SmartSolar MPPT 75/15',
    mac: 'E6:A0:1C:8F:B4:C3',
    encryptionKey: '9c3160efb42104e92c1805d95f75f3f9',
    kind: 'solar',
  ),
];

// Batterikonfiguration
const double kBatteryCapacityAh = 150.0;
const String kBatteryType = 'LiFePO4';
const double kSolarPanelMaxW = 160.0;

// Larmgränser (SoC %)
const double kSocWarn = 30.0;
const double kSocCritical = 20.0;
const double kSocEmergency = 15.0;

// Inverter
const double kInverterIdleAmps = 0.5;

// Hög-förbrukning-larm
const double kHighLoadWattsThreshold = 72.0;
const int kHighLoadMinutes = 10;
