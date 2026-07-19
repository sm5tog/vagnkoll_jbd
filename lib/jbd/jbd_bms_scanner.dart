import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../config/app_config.dart';
import '../victron/victron_parser.dart'; // ShuntReading
import '../victron/victron_scanner.dart'; // VictronState

// JBD BMS BLE-protokoll:
//   Service:  0xFF00
//   Notify:   0xFF01  (svar från BMS)
//   Control:  0xFF02  (kommandon till BMS)
//
// Kommandoformat: DD A5 [REG] 00 [CRC_H] [CRC_L] 77
//   CRC = -(sum(REG + data...)) som int16, big-endian
//
// Register 0x03 = grundinfo (spänning, ström, SoC, temperatur)
// Register 0x04 = cellspänningar

class JbdBmsScanner {
  static final _svcGuid  = Guid('0000FF00-0000-1000-8000-00805F9B34FB');
  static final _ntfGuid  = Guid('0000FF01-0000-1000-8000-00805F9B34FB');
  static final _ctlGuid  = Guid('0000FF02-0000-1000-8000-00805F9B34FB');

  // DD A5 03 00  CRC(-3=FFFD)  77
  static const _cmdBasicInfo = [0xDD, 0xA5, 0x03, 0x00, 0xFF, 0xFD, 0x77];

  final _stateCtrl = StreamController<VictronState>.broadcast();
  final _state = VictronState();

  String? _mac;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _ctlChar;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _ntfSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _pollTimer;
  bool _running = false;
  final List<int> _rxBuf = [];

  Stream<VictronState> get stream => _stateCtrl.stream;
  VictronState get current => _state;

  Future<void> updateDevices(List<JbdDeviceConfig> devices) async {
    final mac = devices.isNotEmpty ? devices.first.mac.toUpperCase() : null;
    if (mac == _mac) return;
    _mac = mac;
    if (_running) {
      await stop();
      await Future.delayed(const Duration(milliseconds: 300));
      if (_mac != null) await start();
    }
  }

  Future<void> start() async {
    if (_mac == null) return;
    _running = true;
    await _scan();
  }

  Future<void> stop() async {
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _scanSub?.cancel();
    _scanSub = null;
    try { await FlutterBluePlus.stopScan(); } catch (_) {}
    await _ntfSub?.cancel();
    _ntfSub = null;
    await _connSub?.cancel();
    _connSub = null;
    try { await _device?.disconnect(); } catch (_) {}
    _device = null;
    _ctlChar = null;
    _rxBuf.clear();
  }

  Future<void> _scan() async {
    if (!_running || _mac == null) return;
    // JBD BMS annonserar inte aktivt — anslut direkt med känt MAC utan scan
    _state.lastError = 'Ansluter till BMS…';
    _stateCtrl.add(_state);
    final device = BluetoothDevice.fromId(_mac!);
    await _connect(device);
  }

  Future<void> _connect(BluetoothDevice device) async {
    if (!_running) return;
    _device = device;

    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && _running) {
        _pollTimer?.cancel();
        _pollTimer = null;
        _ntfSub?.cancel();
        _ntfSub = null;
        _ctlChar = null;
        _device = null;
        Future.delayed(const Duration(seconds: 5), () {
          if (_running) _scan();
        });
      }
    });

    try {
      await device.connect(timeout: const Duration(seconds: 15));
      try { await device.requestMtu(128); } catch (_) {}

      _state.lastError = 'Söker BLE-tjänster…';
      _stateCtrl.add(_state);
      final services = await device.discoverServices();

      BluetoothCharacteristic? ntfChar;
      BluetoothCharacteristic? ctlChar;

      for (final s in services) {
        final uuid = s.serviceUuid.toString().toLowerCase();
        if (uuid == _svcGuid.toString().toLowerCase()) {
          for (final c in s.characteristics) {
            final cuuid = c.characteristicUuid.toString().toLowerCase();
            if (cuuid == _ntfGuid.toString().toLowerCase()) ntfChar = c;
            if (cuuid == _ctlGuid.toString().toLowerCase()) ctlChar = c;
          }
        }
      }

      if (ntfChar == null || ctlChar == null) {
        final found = services.map((s) => s.serviceUuid.toString()).join(', ');
        _state.lastError = 'JBD-tjänst saknas. Hittade: $found';
        _stateCtrl.add(_state);
        await device.disconnect();
        return;
      }

      _ctlChar = ctlChar;
      _rxBuf.clear();
      _state.lastError = null;
      _stateCtrl.add(_state);

      await ntfChar.setNotifyValue(true);
      _ntfSub = ntfChar.onValueReceived.listen(_onNotify);

      _poll();
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    } catch (e) {
      _state.lastError = 'Anslutningsfel: $e';
      _stateCtrl.add(_state);
      _device = null;
      if (_running) {
        Future.delayed(const Duration(seconds: 10), () {
          if (_running) _scan();
        });
      }
    }
  }

  void _poll() {
    _ctlChar?.write(
      Uint8List.fromList(_cmdBasicInfo),
      withoutResponse: false,
    ).catchError((_) {});
  }

  void _onNotify(List<int> bytes) {
    _rxBuf.addAll(bytes);
    _tryParse();
  }

  void _tryParse() {
    while (_rxBuf.length >= 7) {
      final start = _rxBuf.indexOf(0xDD);
      if (start < 0) { _rxBuf.clear(); return; }
      if (start > 0) _rxBuf.removeRange(0, start);
      if (_rxBuf.length < 4) return;

      final len = _rxBuf[3];
      final need = 4 + len + 3; // header(4) + data + CRC(2) + 0x77
      if (_rxBuf.length < need) return;

      final frame = List<int>.from(_rxBuf.sublist(0, need));
      _rxBuf.removeRange(0, need);

      if (frame.last != 0x77) continue;
      if (frame[2] != 0x00) continue; // error-status från BMS

      final reg = frame[1];
      final data = frame.sublist(4, 4 + len);
      if (reg == 0x03) _parseBasicInfo(data);
    }
  }

  void _parseBasicInfo(List<int> data) {
    if (data.length < 23) return;
    final bd = ByteData.sublistView(Uint8List.fromList(data));

    final voltage   = bd.getUint16(0, Endian.big) * 0.01;
    final current   = bd.getInt16(2, Endian.big) * 0.01;
    final remainAh  = bd.getUint16(4, Endian.big) * 0.01;
    final designAh  = bd.getUint16(6, Endian.big) * 0.01;
    final soc       = data[19].toDouble();
    final tempCount = data[22];

    double? temp1;
    if (tempCount >= 1 && data.length >= 25) {
      temp1 = (bd.getUint16(23, Endian.big) - 2731) / 10.0;
    }

    _state.shunt = ShuntReading(
      batteryVoltage: voltage,
      current: current,
      soc: soc,
      consumedAh: -(designAh - remainAh),
      timeToGoMinutes: null,
      alarmReason: 0,
    );
    _state.shuntUpdated = DateTime.now();
    _state.lastError = null;
    _stateCtrl.add(_state);
  }

  void dispose() {
    _stateCtrl.close();
    stop();
  }
}
