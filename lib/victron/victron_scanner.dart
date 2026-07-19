import 'victron_parser.dart';

class VictronState {
  ShuntReading? shunt;
  SolarReading? solar;
  DateTime? shuntUpdated;
  DateTime? solarUpdated;
  // Diagnostik
  int totalBleDevicesSeen = 0;
  int victronAdvertsSeen = 0;
  int decryptFailures = 0;
  final Set<String> seenMacs = {};
  String? lastRawHex;
  String? lastKeyMismatch; // "förväntade XX, fick YY"
  String? lastError;
  String? lastAllMfgKeys; // alla manufacturer-ID:n vi sett
  int lastRawLength = 0;
  String? lastShuntDecryptedHex;
}

