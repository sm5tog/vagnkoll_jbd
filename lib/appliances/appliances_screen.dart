import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../victron/victron_scanner.dart';
import 'appliance_store.dart';
import 'classifier.dart';
import 'load_calculator.dart';
import 'trainer.dart';

typedef PauseResume = void Function();

class AppliancesScreen extends StatefulWidget {
  final ApplianceStore store;
  final VictronScanner scanner;
  final Classifier? classifier;
  final List<PauseResume> pauseHooks;
  final List<PauseResume> resumeHooks;
  const AppliancesScreen({
    super.key,
    required this.store,
    required this.scanner,
    this.classifier,
    this.pauseHooks = const [],
    this.resumeHooks = const [],
  });

  @override
  State<AppliancesScreen> createState() => _AppliancesScreenState();
}

class _AppliancesScreenState extends State<AppliancesScreen> {
  List<Appliance> _appliances = [];
  StreamSubscription? _changeSub;

  @override
  void initState() {
    super.initState();
    _load();
    _changeSub = widget.store.changes.listen((_) => _load());
  }

  Future<void> _load() async {
    final list = await widget.store.all();
    if (!mounted) return;
    setState(() => _appliances = list);
  }

  @override
  void dispose() {
    _changeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Apparater'),
        backgroundColor: const Color(0xFF111827),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'export':
                  _export();
                  break;
                case 'import':
                  _import();
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('Exportera till fil')),
              PopupMenuItem(value: 'import', child: Text('Importera från fil')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _editAppliance(null),
          ),
        ],
      ),
      body: _appliances.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Inga apparater inlagda än.\n\nTryck + uppe till höger för att lägga till.',
                  style: TextStyle(color: Color(0xFF9CA3AF)),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: _appliances.length,
              itemBuilder: (_, i) => _tile(_appliances[i]),
            ),
    );
  }

  Widget _tile(Appliance a) {
    final color = switch (a.category) {
      ApplianceCategory.warn => const Color(0xFFEF4444),
      ApplianceCategory.friendly => const Color(0xFFFBBF24),
      ApplianceCategory.load => Colors.white,
    };
    final icon = switch (a.category) {
      ApplianceCategory.warn => Icons.warning,
      ApplianceCategory.friendly => Icons.coffee,
      ApplianceCategory.load => Icons.bolt,
    };
    return Dismissible(
      key: ValueKey(a.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        color: const Color(0xFFEF4444),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: const Icon(Icons.delete),
      ),
      onDismissed: (_) => widget.store.delete(a.id!),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(a.name),
        subtitle: Text(
          '${a.expectedWatts.toStringAsFixed(0)} W ±${a.tolerancePct.toStringAsFixed(0)}% • '
          'min ${a.minDurationSec}s',
          style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
        ),
        trailing: const Icon(Icons.edit, size: 18, color: Color(0xFF6B7280)),
        onTap: () => _editAppliance(a),
      ),
    );
  }

  Future<void> _editAppliance(Appliance? existing) async {
    widget.classifier?.pause();
    for (final p in widget.pauseHooks) {
      try { p(); } catch (_) {}
    }
    final result = await Navigator.of(context).push<Appliance>(
      MaterialPageRoute(
        builder: (_) => _ApplianceFormScreen(
          existing: existing,
          scanner: widget.scanner,
        ),
      ),
    );
    widget.classifier?.resume();
    for (final r in widget.resumeHooks) {
      try { r(); } catch (_) {}
    }
    if (result == null) return;
    if (existing == null) {
      await widget.store.insert(result);
    } else {
      await widget.store.update(existing.id!, result);
    }
  }

  Future<void> _export() async {
    final json = await widget.store.exportJson();
    final bytes = utf8.encode(json);
    final ts = DateTime.now().toIso8601String().substring(0, 16).replaceAll(':', '');
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Spara apparatbibliotek',
      fileName: 'vagnkoll-apparater-$ts.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: bytes,
    );
    if (!mounted) return;
    if (path != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Sparade ${_appliances.length} apparater'),
      ));
    }
  }

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final file = result.files.first;
    String content;
    if (file.bytes != null) {
      content = String.fromCharCodes(file.bytes!);
    } else if (file.path != null) {
      content = await File(file.path!).readAsString();
    } else {
      return;
    }
    try {
      final n = await widget.store.importJson(content);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Importerade $n apparater'),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Fel vid import: $e'),
      ));
    }
  }
}

class _ApplianceFormScreen extends StatefulWidget {
  final Appliance? existing;
  final VictronScanner scanner;
  const _ApplianceFormScreen({required this.existing, required this.scanner});

  @override
  State<_ApplianceFormScreen> createState() => _ApplianceFormScreenState();
}

class _ApplianceFormScreenState extends State<_ApplianceFormScreen> {
  late TextEditingController _nameCtl;
  late TextEditingController _wattsCtl;
  late TextEditingController _tolCtl;
  late TextEditingController _messageCtl;
  late TextEditingController _durCtl;
  late ApplianceCategory _cat;

  final _measure = QuickMeasure();
  StreamSubscription<QuickMeasureState>? _measureSub;
  StreamSubscription<VictronState>? _liveSub;
  QuickMeasureState? _measureState;
  bool _measuring = false;
  double _liveLoadW = 0;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtl = TextEditingController(text: e?.name ?? '');
    _wattsCtl = TextEditingController(text: e?.expectedWatts.toStringAsFixed(0) ?? '');
    _tolCtl = TextEditingController(text: (e?.tolerancePct ?? 10).toStringAsFixed(0));
    _messageCtl = TextEditingController(text: e?.customMessage ?? '');
    _durCtl = TextEditingController(text: (e?.minDurationSec ?? 5).toString());
    _cat = e?.category ?? ApplianceCategory.load;
    _liveSub = widget.scanner.stream.listen((s) {
      final v = s.shunt?.batteryVoltage ?? s.solar?.batteryVoltage;
      final l = LoadCalculator.load(s);
      if (v != null && v > 0 && l != null && mounted) {
        setState(() => _liveLoadW = l * v);
      }
    });
  }

  @override
  void dispose() {
    _measureSub?.cancel();
    _liveSub?.cancel();
    _measure.dispose();
    _nameCtl.dispose();
    _wattsCtl.dispose();
    _tolCtl.dispose();
    _messageCtl.dispose();
    _durCtl.dispose();
    super.dispose();
  }

  void _startMeasure() {
    setState(() => _measuring = true);
    _measureSub?.cancel();
    _measureSub = _measure.stream.listen((s) {
      if (!mounted) return;
      setState(() => _measureState = s);
      if (s.done) {
        _measuring = false;
        _wattsCtl.text = s.averageWatts.toStringAsFixed(0);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Mätt: ${s.averageWatts.toStringAsFixed(0)} W'),
        ));
      }
    });
    _measure.start(widget.scanner);
  }

  void _save() {
    final name = _nameCtl.text.trim();
    final watts = double.tryParse(_wattsCtl.text.replaceAll(',', '.'));
    if (name.isEmpty || watts == null || watts <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Fyll i namn och en giltig effekt (W).'),
      ));
      return;
    }
    final tol = double.tryParse(_tolCtl.text.replaceAll(',', '.')) ?? 10.0;
    final dur = int.tryParse(_durCtl.text) ?? 5;
    final msg = _messageCtl.text.trim();
    final a = Appliance(
      id: widget.existing?.id,
      name: name,
      category: _cat,
      expectedWatts: watts,
      tolerancePct: tol,
      customMessage: msg.isEmpty ? null : msg,
      minDurationSec: dur,
      createdAt: widget.existing?.createdAt ?? DateTime.now(),
    );
    Navigator.of(context).pop(a);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Redigera apparat' : 'Ny apparat'),
        backgroundColor: const Color(0xFF111827),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('SPARA'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _nameCtl,
            inputFormatters: [LengthLimitingTextInputFormatter(40)],
            decoration: const InputDecoration(
              labelText: 'Namn',
              hintText: 'T.ex. Kaffe, Vattenpump, Golvvärme',
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<ApplianceCategory>(
            value: _cat,
            decoration: const InputDecoration(labelText: 'Typ'),
            items: const [
              DropdownMenuItem(
                value: ApplianceCategory.load,
                child: Text('Vanlig last'),
              ),
              DropdownMenuItem(
                value: ApplianceCategory.friendly,
                child: Text('Glädje (kaffe, etc)'),
              ),
              DropdownMenuItem(
                value: ApplianceCategory.warn,
                child: Text('Varning (golvvärme, kylskåp 230V)'),
              ),
            ],
            onChanged: (v) => setState(() => _cat = v ?? ApplianceCategory.load),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _wattsCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Förväntad effekt',
                    suffixText: 'W',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _tolCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Tolerans',
                    suffixText: '%',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Aktuell last: ${_liveLoadW.toStringAsFixed(0)} W',
            style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
          ),
          const SizedBox(height: 12),
          if (!_measuring)
            OutlinedButton.icon(
              onPressed: _startMeasure,
              icon: const Icon(Icons.timer),
              label: const Text('Mät nu (5 sek)'),
            )
          else
            Column(
              children: [
                LinearProgressIndicator(
                  value: (_measureState?.elapsedSec ?? 0) /
                      QuickMeasure.measureDuration.inSeconds,
                ),
                const SizedBox(height: 8),
                Text(
                  'Mäter… ${_measureState?.elapsedSec.toStringAsFixed(1) ?? "0.0"}s '
                  '(${_measureState?.sampleCount ?? 0} samples)',
                  style: const TextStyle(color: Color(0xFF9CA3AF)),
                ),
              ],
            ),
          const SizedBox(height: 24),
          TextField(
            controller: _messageCtl,
            inputFormatters: [LengthLimitingTextInputFormatter(80)],
            decoration: const InputDecoration(
              labelText: 'Eget meddelande (valfritt)',
              hintText: 'T.ex. "Kokar du kaffe? Gott!"',
              helperText: 'Visas när apparaten detekteras (annars standardmeddelande)',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _durCtl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Min varaktighet för larm',
              suffixText: 'sek',
              helperText: 'Hur länge måste lasten matcha innan apparaten räknas som aktiv',
            ),
          ),
        ],
      ),
    );
  }
}
