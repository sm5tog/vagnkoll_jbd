import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../config/app_config.dart';

class SetupScreen extends StatefulWidget {
  final List<FutureOr<void> Function()> pauseHooks;
  final List<FutureOr<void> Function()> resumeHooks;
  final VoidCallback? onConfigSaved;
  final bool isOnboarding;

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

class _DiscoveredDevice {
  final String mac;
  final String name;
  _DiscoveredDevice(this.mac, this.name);
}

class _SetupScreenState extends State<SetupScreen> {
  AppConfig? _config;
  bool _loading = true;
  bool _scanning = false;
  bool _saving = false;

  StreamSubscription<List<ScanResult>>? _scanSub;
  final Map<String, _DiscoveredDevice> _discovered = {};
  JbdDeviceConfig? _selected;

  final _battery = TextEditingController();
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
    for (final p in widget.pauseHooks) await p();
    final cfg = await AppConfig.load();
    if (!mounted) return;
    setState(() {
      _config = cfg;
      _battery.text = cfg.batteryCapacityAh.toStringAsFixed(0);
      _batteryType = cfg.batteryType;
      _socWarn.text = cfg.socWarn.toStringAsFixed(0);
      _socCritical.text = cfg.socCritical.toStringAsFixed(0);
      _socEmergency.text = cfg.socEmergency.toStringAsFixed(0);
      _inverterIdle.text = cfg.inverterIdleAmps.toStringAsFixed(1);
      _highLoadW.text = cfg.highLoadWattsThreshold.toStringAsFixed(0);
      _highLoadMin.text = cfg.highLoadMinutes.toString();
      _selected = cfg.devices.isNotEmpty ? cfg.devices.first : null;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _stopScan();
    _battery.dispose();
    _socWarn.dispose();
    _socCritical.dispose();
    _socEmergency.dispose();
    _inverterIdle.dispose();
    _highLoadW.dispose();
    _highLoadMin.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _discovered.clear();
      _scanning = true;
    });
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final mac = r.device.remoteId.str.toUpperCase();
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName.isNotEmpty
                ? r.device.platformName
                : 'Okänd';
        if (mounted) {
          setState(() => _discovered[mac] = _DiscoveredDevice(mac, name));
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    await Future.delayed(const Duration(seconds: 11));
    if (mounted) setState(() => _scanning = false);
  }

  void _stopScan() {
    _scanSub?.cancel();
    _scanSub = null;
    try { FlutterBluePlus.stopScan(); } catch (_) {}
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final devices = _selected != null ? [_selected!] : <JbdDeviceConfig>[];
      final cfg = AppConfig(
        devices: devices,
        batteryCapacityAh: double.tryParse(_battery.text) ?? 100.0,
        batteryType: _batteryType,
        socWarn: double.tryParse(_socWarn.text) ?? 30.0,
        socCritical: double.tryParse(_socCritical.text) ?? 20.0,
        socEmergency: double.tryParse(_socEmergency.text) ?? 15.0,
        inverterIdleAmps: double.tryParse(_inverterIdle.text) ?? 0.5,
        highLoadWattsThreshold: double.tryParse(_highLoadW.text) ?? 72.0,
        highLoadMinutes: int.tryParse(_highLoadMin.text) ?? 10,
      );
      await cfg.save();
      await AppConfig.markOnboardingDone();
      widget.onConfigSaved?.call();
      for (final r in widget.resumeHooks) await r();
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Setup'),
        backgroundColor: const Color(0xFF111827),
        automaticallyImplyLeading: !widget.isOnboarding,
      ),
      backgroundColor: const Color(0xFF0A0E1A),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionHeader('JBD BMS'),
            const SizedBox(height: 8),
            _selectedDeviceTile(),
            const SizedBox(height: 8),
            _scanSection(),
            const SizedBox(height: 24),
            _sectionHeader('Batteri'),
            const SizedBox(height: 8),
            _textField(_battery, 'Kapacitet (Ah)', keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _batteryType,
              decoration: _inputDecoration('Batterityp'),
              dropdownColor: const Color(0xFF1F2937),
              items: _kBatteryTypes
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: (v) => setState(() => _batteryType = v ?? _batteryType),
            ),
            const SizedBox(height: 24),
            _sectionHeader('Larmtrösklar'),
            const SizedBox(height: 8),
            _textField(_socWarn, 'SoC varning (%)', keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            _textField(_socCritical, 'SoC kritisk (%)', keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            _textField(_socEmergency, 'SoC nödstopp (%)', keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            _textField(_inverterIdle, 'Inverter-tomgång (A)', keyboardType: TextInputType.numberWithOptions(decimal: true)),
            const SizedBox(height: 8),
            _textField(_highLoadW, 'Hög last-tröskel (W)', keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            _textField(_highLoadMin, 'Hög last-tid (min)', keyboardType: TextInputType.number),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4ADE80),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Text('Spara', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            if (widget.isOnboarding) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () async {
                  await AppConfig.markOnboardingDone();
                  for (final r in widget.resumeHooks) await r();
                  if (mounted) Navigator.of(context).pop();
                },
                child: const Text('Hoppa över', style: TextStyle(color: Color(0xFF6B7280))),
              ),
            ],
            const SizedBox(height: 24),
            TextButton(
              onPressed: () async {
                await AppConfig.clearAll();
                setState(() {
                  _selected = null;
                  _config = AppConfig.defaults();
                  _battery.text = _config!.batteryCapacityAh.toStringAsFixed(0);
                  _socWarn.text = _config!.socWarn.toStringAsFixed(0);
                  _socCritical.text = _config!.socCritical.toStringAsFixed(0);
                  _socEmergency.text = _config!.socEmergency.toStringAsFixed(0);
                  _inverterIdle.text = _config!.inverterIdleAmps.toStringAsFixed(1);
                  _highLoadW.text = _config!.highLoadWattsThreshold.toStringAsFixed(0);
                  _highLoadMin.text = _config!.highLoadMinutes.toString();
                });
              },
              child: const Text('Återställ fabriksinställningar',
                  style: TextStyle(color: Color(0xFFEF4444), fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectedDeviceTile() {
    if (_selected == null) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF374151)),
        ),
        child: const Text('Ingen enhet vald',
            style: TextStyle(color: Color(0xFF6B7280))),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF4ADE80)),
      ),
      child: Row(
        children: [
          const Icon(Icons.bluetooth_connected,
              color: Color(0xFF4ADE80), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_selected!.name,
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
                Text(_selected!.mac,
                    style: const TextStyle(
                        color: Color(0xFF6B7280), fontSize: 12, fontFamily: 'monospace')),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
            onPressed: () => setState(() => _selected = null),
          ),
        ],
      ),
    );
  }

  Widget _scanSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _scanning ? null : _startScan,
          icon: _scanning
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.search, size: 18),
          label: Text(_scanning ? 'Skannar…' : 'Skanna efter BMS'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF4ADE80),
            side: const BorderSide(color: Color(0xFF374151)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        if (_discovered.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...(_discovered.values.map((d) => _deviceListTile(d))),
        ],
      ],
    );
  }

  Widget _deviceListTile(_DiscoveredDevice d) {
    final isSelected = _selected?.mac == d.mac;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
      tileColor: const Color(0xFF111827),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isSelected ? const Color(0xFF4ADE80) : const Color(0xFF374151),
        ),
      ),
      leading: Icon(
        Icons.bluetooth,
        color: isSelected ? const Color(0xFF4ADE80) : const Color(0xFF6B7280),
        size: 20,
      ),
      title: Text(d.name, style: const TextStyle(fontSize: 14)),
      subtitle: Text(d.mac,
          style: const TextStyle(
              color: Color(0xFF6B7280), fontSize: 11, fontFamily: 'monospace')),
      onTap: () => setState(() =>
          _selected = JbdDeviceConfig(name: d.name, mac: d.mac)),
    );
  }

  Widget _sectionHeader(String text) => Text(
        text,
        style: const TextStyle(
            color: Color(0xFF9CA3AF), fontSize: 11, letterSpacing: 2),
      );

  InputDecoration _inputDecoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF6B7280)),
        filled: true,
        fillColor: const Color(0xFF111827),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF374151)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF4ADE80)),
        ),
      );

  Widget _textField(TextEditingController c, String label,
      {TextInputType? keyboardType}) =>
      TextField(
        controller: c,
        keyboardType: keyboardType,
        style: const TextStyle(color: Colors.white),
        decoration: _inputDecoration(label),
      );
}
