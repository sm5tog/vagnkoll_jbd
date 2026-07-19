import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../alarms/alarm_engine.dart';
import '../appliances/appliance_store.dart';
import '../appliances/classifier.dart';
import '../appliances/load_calculator.dart';
import '../config/app_config.dart';
import '../energy_counter.dart';
import '../victron/victron_scanner.dart';

class WebServer {
  static const int port = 8080;

  final VictronScanner scanner;
  final EnergyCounter energy;
  final Classifier classifier;
  final AlarmEngine alarms;

  double _batteryCapacityAh = 100.0;
  double _socWarn = 30.0;
  double _socCritical = 20.0;

  HttpServer? _server;
  String? _ipAddress;
  String? get ipAddress => _ipAddress;

  WebServer({
    required this.scanner,
    required this.energy,
    required this.classifier,
    required this.alarms,
  });

  void updateConfig(AppConfig cfg) {
    _batteryCapacityAh = cfg.batteryCapacityAh;
    _socWarn = cfg.socWarn;
    _socCritical = cfg.socCritical;
  }

  Future<void> start() async {
    final handler = const Pipeline().addHandler(_handleRequest);
    try {
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
      _ipAddress = await _getLocalIp();
    } catch (e) {
      _ipAddress = null;
    }
  }

  Future<String?> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      // Föredra WiFi-interface (oftast wlan0)
      for (final i in interfaces) {
        if (i.name.toLowerCase().contains('wlan') ||
            i.name.toLowerCase().contains('wifi')) {
          if (i.addresses.isNotEmpty) return i.addresses.first.address;
        }
      }
      // Annars första bästa
      for (final i in interfaces) {
        if (i.addresses.isNotEmpty) return i.addresses.first.address;
      }
    } catch (_) {}
    return null;
  }

  // Stale-trösklar: visa diskret ålder över "warn", röd banner när "alarm"
  static const int _staleWarnSec = 15;
  static const int _staleAlarmSec = 30;

  Future<Response> _handleRequest(Request request) async {
    final state = scanner.current;
    final shunt = state.shunt;
    final solar = state.solar;
    final voltage = shunt?.batteryVoltage ?? solar?.batteryVoltage;
    final loadA = LoadCalculator.load(state);
    final loadW = (voltage != null && loadA != null) ? loadA * voltage : null;
    final solarA = (voltage != null && solar != null && voltage > 0)
        ? solar.pvPower / voltage
        : null;
    final ahKvar =
        shunt?.soc != null ? _batteryCapacityAh * shunt!.soc / 100 : null;

    final activeAppliances = classifier.last?.activeAppliances ?? const <Appliance>[];
    final activeAlarms = alarms.current;

    final now = DateTime.now();
    final shuntAge = state.shuntUpdated == null
        ? null
        : now.difference(state.shuntUpdated!).inSeconds;
    final solarAge = state.solarUpdated == null
        ? null
        : now.difference(state.solarUpdated!).inSeconds;
    final shuntStale = shuntAge != null && shuntAge >= _staleWarnSec;
    final solarStale = solarAge != null && solarAge >= _staleWarnSec;
    final bothAlarm = (shuntAge == null || shuntAge >= _staleAlarmSec) &&
        (solarAge == null || solarAge >= _staleAlarmSec);
    final hasEverReceived = state.shuntUpdated != null || state.solarUpdated != null;

    String ageSuffix(int? age) {
      if (age == null || age < _staleWarnSec) return '';
      return ' <span style="color:#FBBF24">($age s sen)</span>';
    }

    String fmt(double? v, [int dec = 2]) =>
        v == null || v.isNaN ? '—' : v.toStringAsFixed(dec);

    // Beräkna återstående laddtid eller urladdningstid baserat på nuvarande
    // ström. LiFePO4-laddning är optimistisk vid hög SoC pga absorption-fasen.
    String? etaText;
    String etaColor = '#9CA3AF';
    if (shunt != null && !shunt.soc.isNaN && !shunt.current.isNaN) {
      final c = shunt.current;
      final soc = shunt.soc;
      if (c > 0.5 && soc < 100) {
        final remainingAh = (100 - soc) / 100 * _batteryCapacityAh;
        final hours = remainingAh / c;
        etaText = 'Full om ${_fmtDuration(hours)}';
        etaColor = '#4ADE80';
      } else if (c < -0.5 && soc > 0) {
        final usableAh = soc / 100 * _batteryCapacityAh;
        final hours = usableAh / c.abs();
        etaText = 'Tom om ${_fmtDuration(hours)}';
        etaColor = '#FBBF24';
      }
    }

    final html = '''
<!DOCTYPE html>
<html lang="sv">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="3">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>Vagnkoll</title>
<style>
  body {
    background: #0A0E1A; color: #fff;
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    margin: 0; padding: 16px;
    font-variant-numeric: tabular-nums;
  }
  .label { color: #6B7280; font-size: 11px; letter-spacing: 2px; }
  .label-ok { color: #4ADE80; }
  .box {
    background: #111827; padding: 14px 18px;
    border-radius: 14px; margin-bottom: 10px;
  }
  .big {
    font-size: 56px; font-weight: 200;
    color: ${_socColorCss(shunt?.soc)};
  }
  .eta { font-size: 14px; font-weight: 300; margin-top: -6px; clear: both; }
  .right { float: right; text-align: right; font-size: 14px; color: rgba(255,255,255,0.7); }
  .small-row { display: flex; gap: 12px; margin-bottom: 10px; }
  .small-row .box { flex: 1; padding: 10px 12px; margin-bottom: 0; }
  .small-val { font-size: 26px; font-weight: 300; }
  .alarm {
    padding: 10px 12px; margin-bottom: 8px;
    border-radius: 8px; font-size: 13px;
  }
  .alarm-emergency, .alarm-critical { background: rgba(239,68,68,0.15); border: 1px solid #EF4444; color: #EF4444; }
  .alarm-warn { background: rgba(251,191,36,0.15); border: 1px solid #FBBF24; color: #FBBF24; }
  .alarm-info { background: rgba(74,222,128,0.15); border: 1px solid #4ADE80; color: #4ADE80; }
  .footer { color: #4B5563; font-size: 11px; margin-top: 16px; }
</style>
</head>
<body>
  <div style="color:#6B7280; letter-spacing:4px; font-size:13px; margin-bottom:12px;">VAGNKOLL</div>

  ${bothAlarm && hasEverReceived ? '<div class="alarm alarm-critical">⚠ Ingen Victron-data på ${shuntAge ?? solarAge ?? 0} s — kontrollera BLE/telefon</div>' : ''}
  ${!hasEverReceived ? '<div class="alarm alarm-warn">⏳ Väntar på första Victron-paket…</div>' : ''}

  <div class="box">
    <div class="label ${shunt != null && !shuntStale ? 'label-ok' : ''}">BATTERI${ageSuffix(shuntAge)}</div>
    <div class="right">
      ${shunt != null ? '${fmt(shunt.batteryVoltage)} V<br>${shunt.current >= 0 ? '+' : ''}${fmt(shunt.current)} A' : ''}
      ${ahKvar != null ? '<br>${fmt(ahKvar, 1)} Ah kvar' : ''}
    </div>
    <div class="big">${fmt(shunt?.soc, 1)} %</div>
    ${etaText != null ? '<div class="eta" style="color:$etaColor">$etaText</div>' : ''}
  </div>

  <div class="small-row">
    <div class="box">
      <div class="label ${solar != null && !solarStale ? 'label-ok' : ''}">SOL${ageSuffix(solarAge)}</div>
      <div class="small-val" style="color:#FBBF24">
        ${solarA != null && solar != null ? '${fmt(solarA, 1)}A/${fmt(solar.pvPower, 0)}W' : '—'}
      </div>
    </div>
    <div class="box">
      <div class="label">LADDAT IDAG</div>
      <div class="small-val" style="color:#4ADE80">${fmt(energy.solarAhToday, 1)} Ah</div>
    </div>
  </div>

  <div class="small-row">
    <div class="box">
      <div class="label">FÖRBRUKNING</div>
      <div class="small-val" style="color:#EF4444">
        ${loadA != null ? '${fmt(loadA, 1)}A' : '—'}${loadW != null ? '/${fmt(loadW, 0)}W' : ''}
      </div>
    </div>
    <div class="box">
      <div class="label">ANVÄNT IDAG</div>
      <div class="small-val" style="color:#EF4444">${fmt(energy.usedAhToday, 1)} Ah</div>
    </div>
  </div>

  ${activeAlarms.map((a) => '<div class="alarm alarm-${a.level.name}">${_esc(a.message)}</div>').join()}

  ${activeAppliances.isNotEmpty ? '<div style="color:#9CA3AF; font-size:13px; margin-top:8px;">Aktivt nu: ${activeAppliances.map((a) => _esc(a.name)).join(', ')}</div>' : ''}

  ${solar != null ? '<div style="color:#9CA3AF; font-size:13px;">Laddläge: ${_esc(solar.chargeStateName)}</div>' : ''}

  <div class="footer">Uppdaterad ${DateTime.now().toString().substring(11, 19)} • Auto-refresh 3 sek</div>
</body>
</html>
''';
    return Response.ok(
      html,
      headers: {'Content-Type': 'text/html; charset=utf-8'},
    );
  }

  static String _fmtDuration(double hours) {
    if (hours.isNaN || hours.isInfinite || hours <= 0) return '—';
    if (hours > 99) return '>99 h';
    final totalMin = (hours * 60).round();
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    if (h == 0) return '$m min';
    if (m == 0) return '$h h';
    return '$h h $m min';
  }

  static String _esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  String _socColorCss(double? soc) {
    if (soc == null) return '#9CA3AF';
    if (soc < _socCritical) return '#EF4444';
    if (soc < _socWarn) return '#FBBF24';
    return '#4ADE80';
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}
