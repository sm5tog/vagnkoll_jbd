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
  final _logCtrl   = StreamController<String>.broadcast();
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
  Stream<String> get logStream => _logCtrl.stream;
  VictronState get current => _state;

  void _log(String msg) {
    final ts = DateTime.now().toString().substring(11, 19);
    _logCtrl.add('[$ts] $msg');
  }

  void _status(String msg) {
    _log(msg);
    _state.lastError = msg;
    _stateCtrl.add(_state);
  }

  Future<void> updateDevices(List<JbdDeviceConfig> devices) async {
    final mac = devices.isNotEmpty ? devices.first.mac.toUpperCase() : null;
    if (mac == _mac) return;
    _log('updateDevices: MAC ändrat ${_mac ?? "null"} → ${mac ?? "null"}');
    _mac = mac;
    if (_running) {
      await stop();
      await Future.delayed(const Duration(milliseconds: 300));
      if (_mac != null) await start();
    }
  }

  Future<void> start() async {
    if (_mac == null) { _log('start() avbrutet: ingen MAC'); return; }
    _log('start() MAC=$_mac');
    _running = true;
    await _scan();
  }

  Future<void> stop() async {
    _log('stop()');
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
    _status('Ansluter till $_mac…');
    final device = BluetoothDevice.fromId(_mac!);
    await _connect(device);
  }

  Future<void> _connect(BluetoothDevice device) async {
    if (!_running) return;
    _device = device;

    try {
      _log('connect() anropas (timeout 15s)…');
      await device.connect(timeout: const Duration(seconds: 15));
      _log('connect() lyckades');

      // Sätt upp disconnect-lyssnare EFTER lyckad anslutning
      _connSub = device.connectionState.listen((s) {
        _log('connectionState: $s');
        if (s == BluetoothConnectionState.disconnected && _running) {
          _pollTimer?.cancel();
          _pollTimer = null;
          _ntfSub?.cancel();
          _ntfSub = null;
          _ctlChar = null;
          _device = null;
          _status('Frånkopplad. Försöker igen om 5s…');
          Future.delayed(const Duration(seconds: 5), () {
            if (_running) _scan();
          });
        }
      });

      try {
        await device.requestMtu(128);
        _log('MTU 128 OK');
      } catch (e) {
        _log('MTU-fel (ignoreras): $e');
      }

      _status('Söker BLE-tjänster…');
      final services = await device.discoverServices();
      _log('discoverServices: ${services.length} tjänster');
      for (final s in services) {
        _log('  tjänst: ${s.serviceUuid}');
      }

      BluetoothCharacteristic? ntfChar;
      BluetoothCharacteristic? ctlChar;

      final svcTarget = _svcGuid.toString().toLowerCase();
      final ntfTarget = _ntfGuid.toString().toLowerCase();
      final ctlTarget = _ctlGuid.toString().toLowerCase();

      for (final s in services) {
        final uuid = s.serviceUuid.toString().toLowerCase();
        if (uuid == svcTarget) {
          _log('JBD-tjänst hittad! Söker characteristics…');
          for (final c in s.characteristics) {
            final cuuid = c.characteristicUuid.toString().toLowerCase();
            _log('  char: $cuuid');
            if (cuuid == ntfTarget) ntfChar = c;
            if (cuuid == ctlTarget) ctlChar = c;
          }
        }
      }

      if (ntfChar == null || ctlChar == null) {
        final found = services.map((s) => s.serviceUuid.toString()).join(', ');
        _status('FF00-tjänst saknas. Hittade: $found');
        await device.disconnect();
        return;
      }

      _log('ntfChar och ctlChar hittade. Aktiverar notify…');
      _ctlChar = ctlChar;
      _rxBuf.clear();

      await ntfChar.setNotifyValue(true);
      _log('setNotifyValue(true) OK');
      _ntfSub = ntfChar.onValueReceived.listen(_onNotify);

      _log('Startar polling (var 2s)');
      _state.lastError = null;
      _stateCtrl.add(_state);
      _poll();
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    } catch (e) {
      _status('Anslutningsfel: $e');
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
    ).then((_) {
      _log('poll() skickad');
    }).catchError((e) {
      _log('poll() fel: $e');
    });
  }

  void _onNotify(List<int> bytes) {
    _log('notify: ${bytes.length} bytes: ${bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
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
      _log('frame reg=0x${reg.toRadixString(16)} len=$len');
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

    _log('parseBasicInfo: ${voltage.toStringAsFixed(2)}V ${current.toStringAsFixed(2)}A SoC=${soc.toStringAsFixed(0)}% temp=${temp1?.toStringAsFixed(1) ?? "?"}°C');
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
    _logCtrl.close();
    stop();
  }
}
