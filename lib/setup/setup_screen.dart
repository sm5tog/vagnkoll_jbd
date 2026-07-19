import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../config/app_config.dart';

/// Setup-skärm för Vagnkoll. Låter användaren:
///  - skanna efter Victron-enheter via BLE
///  - mata in encryption key per enhet (hämtas i VictronConnect)
///  - konfigurera batterikapacitet, sol-max, larmtrösklar
///
/// `pauseHooks` / `resumeHooks` används precis som i `AppliancesScreen` —
/// huvud-scannern pausas under setup så vi kan göra en obegränsad BLE-scan.
class SetupScreen extends StatefulWidget {
  final List<FutureOr<void> Function()> pauseHooks;
  final List<FutureOr<void> Function()> resumeHooks;
  final VoidCallback? onConfigSaved;
  final bool isOnboarding; // True → "hoppa över" syns, ingen swipe-tillbaka

  const SetupScreen({
    super.key,
    this.pauseHooks = const [],
    this.resumeHooks = const [],
    this.onConfigSaved,
    this.isOnboarding = false,
  });

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  AppConfig? _config;
  bool _loading = true;
  bool _scanning = false;
  bool _saving = false;
  String? _scanError;

  StreamSubscription<List<ScanResult>>? _scanSub;
  final Map<String, _DiscoveredDevice> _discovered = {};

  // Form controllers
  final _battery = TextEditingController();
  final _solar = TextEditingController();
  final _socWarn = TextEditingController();
  final _socCritical = TextEditingController();
  final _socEmergency = TextEditingController();
  final _inverterIdle = TextEditingController();
  final _highLoadW = TextEditingController();
  final _highLoadMin = TextEditingController();
  String _batteryType = 'LiFePO4';

  static const _kBatteryTypes = ['LiFePO4', 'AGM', 'GEL', 'Bly', 'NMC', 'Annat'];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    for (final pause in widget.pauseHooks) {
      await pause();
    }
    final cfg = await AppConfig.load();
    if (!mounted) return;
    setState(() {
      _config = cfg;
      _battery.text = cfg.batteryCapacityAh.toStringAsFixed(0);
      _batteryType = cfg.batteryType;
      _solar.text = cfg.solarMaxW.toStringAsFixed(0);
      _socWarn.text = cfg.socWarn.toStringAsFixed(0);
      _socCritical.text = cfg.socCritical.toStringAsFixed(0);
      _socEmergency.text = cfg.socEmergency.toStringAsFixed(0);
      _inverterIdle.text = cfg.inverterIdleAmps.toStringAsFixed(1);
      _highLoadW.text = cfg.highLoadWattsThreshold.toStringAsFixed(0);
      _highLoadMin.text = cfg.highLoadMinutes.toString();
      _loading = false;
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    for (final resume in widget.resumeHooks) {
      resume();
    }
    _battery.dispose();
    _solar.dispose();
    _socWarn.dispose();
    _socCritical.dispose();
    _socEmergency.dispose();
    _inverterIdle.dispose();
    _highLoadW.dispose();
    _highLoadMin.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _discovered.clear();
      _scanError = null;
    });
    try {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        continuousUpdates: true,
      );
    } catch (e) {
      if (mounted) setState(() => _scanError = e.toString());
    }
    await Future.delayed(const Duration(seconds: 15));
    if (!mounted) return;
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    setState(() => _scanning = false);
  }

  void _onScanResults(List<ScanResult> results) {
    var changed = false;
    for (final r in results) {
      final mac = r.device.remoteId.str.toUpperCase();
      // Snävt Victron-filter: bara mfg ID 0x02E1. Tidigare hade vi en
      // fallback på första-byte 0x10 (Instant Readout-markören) men den
      // släpper in icke-Victron-enheter som råkar börja med samma byte.
      if (!r.advertisementData.manufacturerData.containsKey(0x02E1)) continue;
      final name = r.device.platformName.isNotEmpty
          ? r.device.platformName
          : r.advertisementData.advName;
      final prev = _discovered[mac];
      if (prev == null ||
          prev.rssi != r.rssi ||
          (name.isNotEmpty && prev.name != name)) {
        _discovered[mac] = _DiscoveredDevice(
          mac: mac,
          name: name.isEmpty ? '(okänt namn)' : name,
          rssi: r.rssi,
        );
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  Future<void> _addOrEditDevice(_DiscoveredDevice disc) async {
    final existing = _config!.devices.where((d) => d.mac == disc.mac).firstOrNull;
    final result = await showDialog<VictronDeviceConfig>(
      context: context,
      builder: (_) => _DeviceDialog(discovered: disc, existing: existing),
    );
    if (result == null) return;
    final updated = List<VictronDeviceConfig>.from(_config!.devices)
      ..removeWhere((d) => d.mac == result.mac)
      ..add(result);
    setState(() => _config = _config!.copyWith(devices: updated));
  }

  Future<void> _editExisting(VictronDeviceConfig dev) async {
    // Skapa en "dummy discovered" så dialogen kan visa MAC-en
    final disc = _DiscoveredDevice(mac: dev.mac, name: dev.name, rssi: 0);
    await _addOrEditDevice(disc);
  }

  void _removeDevice(String mac) {
    setState(() {
      _config = _config!.copyWith(
        devices: _config!.devices.where((d) => d.mac != mac).toList(),
      );
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final cfg = _config!.copyWith(
      batteryCapacityAh:
          double.tryParse(_battery.text.replaceAll(',', '.')) ?? 100,
      batteryType: _batteryType,
      solarMaxW:
          double.tryParse(_solar.text.replaceAll(',', '.')) ?? 100,
      socWarn: double.tryParse(_socWarn.text.replaceAll(',', '.')) ?? 30,
      socCritical:
          double.tryParse(_socCritical.text.replaceAll(',', '.')) ?? 20,
      socEmergency:
          double.tryParse(_socEmergency.text.replaceAll(',', '.')) ?? 15,
      inverterIdleAmps:
          double.tryParse(_inverterIdle.text.replaceAll(',', '.')) ?? 0.5,
      highLoadWattsThreshold:
          double.tryParse(_highLoadW.text.replaceAll(',', '.')) ?? 72,
      highLoadMinutes: int.tryParse(_highLoadMin.text) ?? 10,
    );
    await cfg.save();
    await AppConfig.markOnboardingDone();
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onConfigSaved?.call();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sparat')),
      );
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _skipOnboarding() async {
    await AppConfig.markOnboardingDone();
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Återställ?'),
        content: const Text(
          'Detta raderar alla Victron-enheter och encryption keys, samt återställer batteri- och larminställningar till standard. Kan inte ångras.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Avbryt'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFEF4444)),
            child: const Text('Återställ'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppConfig.clearAll();
    if (mounted) await _init();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final cfg = _config!;
    return PopScope(
      // I onboarding-läge får man inte navigera tillbaka — spara eller hoppa över
      canPop: !widget.isOnboarding,
      child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.isOnboarding,
        title: Text(widget.isOnboarding ? 'Välkommen' : 'Inställningar'),
        actions: [
          if (widget.isOnboarding && !_saving)
            TextButton(
              onPressed: _skipOnboarding,
              child: const Text('HOPPA ÖVER'),
            ),
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            TextButton(
              onPressed: _save,
              child: const Text('SPARA'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader('Konfigurerade Victron-enheter'),
          if (cfg.devices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Inga enheter ännu. Sök efter dem nedan.',
                style: TextStyle(color: Color(0xFF6B7280)),
              ),
            )
          else
            ...cfg.devices.map((dev) => Card(
                  child: ListTile(
                    leading: Icon(
                      dev.kind == 'solar' ? Icons.wb_sunny : Icons.battery_charging_full,
                      color: dev.kind == 'solar'
                          ? const Color(0xFFFBBF24)
                          : const Color(0xFF4ADE80),
                    ),
                    title: Text(dev.name),
                    subtitle: Text('${dev.mac}  •  ${dev.kind}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _removeDevice(dev.mac),
                    ),
                    onTap: () => _editExisting(dev),
                  ),
                )),

          const SizedBox(height: 16),
          _sectionHeader('Hittade enheter'),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _scanning ? null : _startScan,
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bluetooth_searching),
                  label: Text(_scanning ? 'Skannar 15 sek…' : 'Sök Victron-enheter'),
                ),
              ),
            ],
          ),
          if (_scanError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Scanningsfel: $_scanError',
                style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12),
              ),
            ),
          if (_discovered.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...(_discovered.values.toList()
                  ..sort((a, b) => b.rssi.compareTo(a.rssi)))
                .map((disc) => Card(
                      child: ListTile(
                        title: Text(disc.name),
                        subtitle: Text('${disc.mac}  •  RSSI ${disc.rssi} dBm'),
                        trailing: cfg.devices.any((d) => d.mac == disc.mac)
                            ? const Icon(Icons.check, color: Color(0xFF4ADE80))
                            : const Icon(Icons.add),
                        onTap: () => _addOrEditDevice(disc),
                      ),
                    )),
          ],

          const SizedBox(height: 24),
          _sectionHeader('Batteri'),
          _numField(_battery, 'Kapacitet (Ah)'),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _batteryType,
            decoration: const InputDecoration(
              labelText: 'Typ',
              border: OutlineInputBorder(),
            ),
            items: _kBatteryTypes
                .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _batteryType = v);
            },
          ),

          const SizedBox(height: 24),
          _sectionHeader('Sol'),
          _numField(_solar, 'Max effekt (W)'),

          const SizedBox(height: 24),
          _sectionHeader('Larmtrösklar'),
          _numField(_socWarn, 'SoC varning (%)'),
          const SizedBox(height: 8),
          _numField(_socCritical, 'SoC kritisk (%)'),
          const SizedBox(height: 8),
          _numField(_socEmergency, 'SoC nöd (%)'),
          const SizedBox(height: 8),
          _numField(_inverterIdle, 'Inverter idle-ström (A)'),
          const SizedBox(height: 8),
          _numField(_highLoadW, 'Hög förbrukning (W)'),
          const SizedBox(height: 8),
          _numField(_highLoadMin, 'Hög förbrukning min. tid (min)'),

          const SizedBox(height: 32),
          OutlinedButton.icon(
            onPressed: _confirmReset,
            icon: const Icon(Icons.restore, color: Color(0xFFEF4444)),
            label: const Text(
              'Återställ fabriksinställningar',
              style: TextStyle(color: Color(0xFFEF4444)),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFFEF4444)),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    ),
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF9CA3AF),
            fontSize: 12,
            letterSpacing: 2,
          ),
        ),
      );

  Widget _numField(TextEditingController c, String label) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      );
}

class _DiscoveredDevice {
  final String mac;
  final String name;
  final int rssi;
  _DiscoveredDevice({required this.mac, required this.name, required this.rssi});
}

class _DeviceDialog extends StatefulWidget {
  final _DiscoveredDevice discovered;
  final VictronDeviceConfig? existing;
  const _DeviceDialog({required this.discovered, this.existing});

  @override
  State<_DeviceDialog> createState() => _DeviceDialogState();
}

class _DeviceDialogState extends State<_DeviceDialog> {
  late TextEditingController _name;
  late TextEditingController _key;
  String _kind = 'shunt';
  String? _guessedKind; // Sätts om vi kunde härleda typ ur namnet
  bool _overrideKind = false; // Om användaren tryckt "ändra" på auto-typen
  String? _clipboardKey; // 32-hex-key hittad i urklippet, om någon
  String? _error;

  static final _hexKey = RegExp(r'^[0-9a-f]+$');

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    _name = TextEditingController(text: ex?.name ?? widget.discovered.name);
    _key = TextEditingController(text: ex?.encryptionKey ?? '');
    if (ex != null) {
      _kind = ex.kind;
      _overrideKind = true; // Redigerar — visa dropdown så typ kan ändras
    } else {
      _guessedKind = _guessKindFromName(widget.discovered.name);
      _kind = _guessedKind ?? 'shunt';
    }
    _peekClipboard();
  }

  Future<void> _peekClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final t = _normalizeKey(data?.text ?? '');
      if (t.length == 32 && _hexKey.hasMatch(t)) {
        if (mounted) setState(() => _clipboardKey = t);
      }
    } catch (_) {
      // Urklippsåtkomst kan blockeras — strunta i tipset då
    }
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final t = _normalizeKey(data?.text ?? '');
      if (t.length == 32 && _hexKey.hasMatch(t)) {
        setState(() {
          _key.text = t;
          _clipboardKey = null;
          _error = null;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Urklipp innehåller ingen 32-hex-nyckel')),
        );
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kunde inte läsa urklipp')),
      );
    }
  }

  static String _normalizeKey(String raw) =>
      raw.trim().toLowerCase().replaceAll(RegExp(r'[\s:]'), '');

  static String? _guessKindFromName(String name) {
    final n = name.toLowerCase();
    if (n.contains('shunt') || n.contains('bmv')) return 'shunt';
    if (n.contains('solar') || n.contains('mppt')) return 'solar';
    return null;
  }

  String _kindLabel(String k) => k == 'solar' ? 'SmartSolar MPPT' : 'SmartShunt';

  @override
  void dispose() {
    _name.dispose();
    _key.dispose();
    super.dispose();
  }

  void _confirm() {
    final key = _normalizeKey(_key.text);
    if (key.length != 32 || !_hexKey.hasMatch(key)) {
      setState(() => _error = 'Nyckeln måste vara 32 hex-tecken (0–9, a–f)');
      return;
    }
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Ange ett namn');
      return;
    }
    Navigator.pop(
      context,
      VictronDeviceConfig(
        name: _name.text.trim(),
        mac: widget.discovered.mac,
        encryptionKey: key,
        kind: _kind,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Lägg till enhet' : 'Redigera enhet'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.discovered.mac,
                style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Namn',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            if (_guessedKind != null && !_overrideKind)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Typ: ${_kindLabel(_kind)} (auto-detekterad)',
                      style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _overrideKind = true),
                    child: const Text('Ändra'),
                  ),
                ],
              )
            else
              DropdownButtonFormField<String>(
                value: _kind,
                decoration: const InputDecoration(
                  labelText: 'Typ',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: 'shunt', child: Text('SmartShunt')),
                  DropdownMenuItem(value: 'solar', child: Text('SmartSolar MPPT')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _kind = v);
                },
              ),
            const SizedBox(height: 12),
            if (_clipboardKey != null && _key.text.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: const Color(0xFF1F2937),
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    onTap: _pasteFromClipboard,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        children: [
                          const Icon(Icons.content_paste,
                              size: 18, color: Color(0xFF4ADE80)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Hittade nyckel i urklipp: ${_clipboardKey!.substring(0, 4)}…${_clipboardKey!.substring(28)}',
                              style: const TextStyle(
                                color: Color(0xFF4ADE80),
                                fontSize: 13,
                              ),
                            ),
                          ),
                          const Text(
                            'KLISTRA IN',
                            style: TextStyle(
                              color: Color(0xFF4ADE80),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            TextField(
              controller: _key,
              decoration: InputDecoration(
                labelText: 'Encryption key (32 hex)',
                border: const OutlineInputBorder(),
                isDense: true,
                helperText:
                    'VictronConnect → enhet → inställningar → produktinfo → Instant Readout. Långtryck nyckeln för att kopiera.',
                helperMaxLines: 3,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste, size: 20),
                  tooltip: 'Klistra in från urklipp',
                  onPressed: _pasteFromClipboard,
                ),
              ),
              maxLength: 40,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Avbryt'),
        ),
        TextButton(onPressed: _confirm, child: const Text('Spara')),
      ],
    );
  }
}

extension _IterableExt<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
