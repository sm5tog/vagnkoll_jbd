import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../config/app_config.dart';
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

class VictronScanner {
  final _stateController = StreamController<VictronState>.broadcast();
  final _state = VictronState();
  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _watchdog;
  DateTime? _lastVictronPacket;
  List<VictronDeviceConfig> _devices = [];

  Stream<VictronState> get stream => _stateController.stream;
  VictronState get current => _state;

  // MAC-adresser till våra Victron-enheter. Android 8.1+ levererar inga
  // scan-resultat när skärmen är låst om vi inte filtrerar på något — så
  // utan denna lista tystnar appen så fort telefonen låses.
  List<String> get _victronMacs => _devices.map((d) => d.mac).toList();

  /// Uppdatera device-listan och starta om scanning med nya MAC:ar.
  /// Säkert att anropa även innan start() — uppdaterar då bara listan.
  Future<void> updateDevices(List<VictronDeviceConfig> devices) async {
    _devices = List.of(devices);
    if (_scanSub != null) {
      try {
        await stop();
        await Future.delayed(const Duration(milliseconds: 300));
        await start();
      } catch (_) {}
    }
  }

  Future<void> start() async {
    _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
    final macs = _victronMacs;
    await FlutterBluePlus.startScan(
      withRemoteIds: macs,
      continuousUpdates: true,
      removeIfGone: const Duration(seconds: 30),
    );
    // Watchdog: starta om scanningen om inga Victron-paket på 20 sek
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) async {
      final last = _lastVictronPacket;
      if (last == null) return;
      if (DateTime.now().difference(last).inSeconds >= 20) {
        // Försök starta om scannern
        try {
          await FlutterBluePlus.stopScan();
          await Future.delayed(const Duration(milliseconds: 500));
          final macs = _victronMacs;
          await FlutterBluePlus.startScan(
            withRemoteIds: macs,
            continuousUpdates: true,
            removeIfGone: const Duration(seconds: 30),
          );
        } catch (_) {}
      }
    });
  }

  Future<void> stop() async {
    _watchdog?.cancel();
    _watchdog = null;
    await _scanSub?.cancel();
    _scanSub = null;
    await FlutterBluePlus.stopScan();
  }

  Future<void> _onScanResults(List<ScanResult> results) async {
    for (final r in results) {
      final mac = r.device.remoteId.str.toUpperCase();
      _state.seenMacs.add(mac);
      _state.totalBleDevicesSeen = _state.seenMacs.length;

      VictronDeviceConfig? match;
      for (final d in _devices) {
        if (d.mac.toUpperCase() == mac) {
          match = d;
          break;
        }
      }
      if (match == null) {
        _stateController.add(_state);
        continue;
      }

      // Logga ALLA mfg-ID vi ser från denna enhet
      final allKeys = r.advertisementData.manufacturerData.keys
          .map((k) => '0x${k.toRadixString(16).padLeft(4, '0')}')
          .join(',');
      _state.lastAllMfgKeys = allKeys;

      // Försök med Victron-ID först, sen alla andra mfg-data
      var mfgData = r.advertisementData.manufacturerData[VictronParser.kVictronManufacturerId];
      if (mfgData == null) {
        // Testa alla mfg-data som börjar med 0x10 (Victron Instant Readout-marker)
        for (final entry in r.advertisementData.manufacturerData.entries) {
          if (entry.value.isNotEmpty && entry.value[0] == 0x10) {
            mfgData = entry.value;
            break;
          }
        }
        if (mfgData == null) continue;
      }
      _state.victronAdvertsSeen++;
      _state.lastRawLength = mfgData.length;

      final result = await VictronParser.parseDetailed(
        Uint8List.fromList(mfgData),
        match.encryptionKey,
      );
      _state.lastRawHex = result.rawHex;
      if (result.error != VictronParseError.ok) {
        _state.decryptFailures++;
        _state.lastError = result.error.name;
        if (result.error == VictronParseError.keyMismatch) {
          final exp = result.expectedKeyByte?.toRadixString(16).padLeft(2, '0');
          final act = result.actualKeyByte?.toRadixString(16).padLeft(2, '0');
          _state.lastKeyMismatch = 'väntade $exp, fick $act';
        }
        _stateController.add(_state);
        continue;
      }
      final advert = result.advert!;

      _lastVictronPacket = DateTime.now();

      if (match.kind == 'shunt') {
        // Diagnostik: spara de dekrypterade bytes så vi kan se rätt layout
        final sb = StringBuffer();
        final n = advert.decryptedPayload.length < 20
            ? advert.decryptedPayload.length
            : 20;
        for (var i = 0; i < n; i++) {
          sb.write(advert.decryptedPayload[i]
              .toRadixString(16)
              .padLeft(2, '0'));
          if ((i + 1) % 4 == 0 && i < n - 1) sb.write(' ');
        }
        _state.lastShuntDecryptedHex = sb.toString();

        final reading = ShuntReading.fromPayload(advert.decryptedPayload);
        if (reading != null) {
          _state.shunt = reading;
          _state.shuntUpdated = DateTime.now();
        }
      } else if (match.kind == 'solar') {
        final reading = SolarReading.fromPayload(advert.decryptedPayload);
        if (reading != null) {
          _state.solar = reading;
          _state.solarUpdated = DateTime.now();
        }
      }
      _stateController.add(_state);
    }
  }

  void dispose() {
    _stateController.close();
    stop();
  }
}
