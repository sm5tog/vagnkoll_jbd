import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'alarms/alarm_engine.dart';
import 'appliances/appliance_store.dart';
import 'appliances/appliances_screen.dart';
import 'appliances/classifier.dart';
import 'build_info.dart';
import 'config/app_config.dart';
import 'energy_counter.dart';
import 'foreground_task.dart';
import 'history/history_screen.dart';
import 'history/history_store.dart';
import 'jbd/jbd_bms_scanner.dart';
import 'setup/setup_screen.dart';
import 'victron/victron_scanner.dart';
import 'web/web_server.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await VagnkollForegroundService.init();
  runApp(const VagnkollApp());
}

class VagnkollApp extends StatelessWidget {
  const VagnkollApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vagnkoll JBD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4ADE80),
          secondary: Color(0xFFFBBF24),
          surface: Color(0xFF111827),
          error: Color(0xFFEF4444),
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(
            fontFeatures: [FontFeature.tabularFigures()],
            fontWeight: FontWeight.w300,
          ),
          displayMedium: TextStyle(
            fontFeatures: [FontFeature.tabularFigures()],
            fontWeight: FontWeight.w300,
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _scanner = JbdBmsScanner();
  final _history = HistoryStore();
  final _energy = EnergyCounter();
  final _appliances = ApplianceStore();
  final _classifier = Classifier();
  final _alarms = AlarmEngine();
  WebServer? _webServer;
  AppConfig _config = AppConfig.defaults();
  StreamSubscription<VictronState>? _sub;
  StreamSubscription<EnergyCounter>? _energySub;
  StreamSubscription<ClassificationResult>? _classSub;
  StreamSubscription<List<Alarm>>? _alarmSub;
  StreamSubscription? _applianceChangesSub;
  Timer? _telemetryTimer;
  VictronState? _state;
  ClassificationResult? _classification;
  List<Alarm> _activeAlarms = [];
  String _status = 'Startar…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _restartScanner();
  }

  Future<void> _restartScanner() async {
    try {
      await _scanner.stop();
      await Future.delayed(const Duration(milliseconds: 500));
      await _scanner.start();
    } catch (_) {}
  }

  Future<void> _init() async {
    final perms = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    if (!perms.values.every((s) => s.isGranted)) {
      setState(() => _status = 'Bluetooth-rättigheter saknas');
      return;
    }

    var cfg = await AppConfig.load();
    final onboardingDone = await AppConfig.isOnboardingDone();
    if (!cfg.isConfigured && !onboardingDone && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const SetupScreen(isOnboarding: true),
          fullscreenDialog: true,
        ),
      );
      cfg = await AppConfig.load();
    }
    _config = cfg;
    await _scanner.updateDevices(_config.devices);

    await _history.open();
    _history.attachScanner(_scanner);
    await _energy.init();
    _energy.attachScanner(_scanner);
    await _appliances.open();
    await _classifier.init();
    _classifier.setLibrary(await _appliances.all());
    _classifier.attachScanner(_scanner);
    _alarms.attach(scanner: _scanner, classifier: _classifier);
    _alarms.updateConfig(_config);

    _sub = _scanner.stream.listen((s) {
      setState(() {
        _state = s;
        _status = '';
      });
    });
    _energySub = _energy.stream.listen((_) {
      if (mounted) setState(() {});
    });
    _classSub = _classifier.stream.listen((r) {
      _alarms.updateActiveAppliances(r.activeAppliances);
      if (mounted) setState(() => _classification = r);
    });
    _alarmSub = _alarms.stream.listen((a) {
      if (mounted) setState(() => _activeAlarms = a);
    });
    _applianceChangesSub = _appliances.changes.listen((_) async {
      _classifier.setLibrary(await _appliances.all());
    });
    await _scanner.start();
    setState(() => _status = 'Ansluter till JBD BMS…');

    _webServer = WebServer(
      scanner: _scanner,
      energy: _energy,
      classifier: _classifier,
      alarms: _alarms,
    );
    await _webServer!.start();
    _webServer!.updateConfig(_config);

    await VagnkollForegroundService.start();
    _telemetryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _energySub?.cancel();
    _classSub?.cancel();
    _alarmSub?.cancel();
    _applianceChangesSub?.cancel();
    _telemetryTimer?.cancel();
    _webServer?.stop();
    VagnkollForegroundService.stop();
    _scanner.dispose();
    _history.close();
    _energy.dispose();
    _classifier.dispose();
    _alarms.dispose();
    _appliances.close();
    WakelockPlus.disable();
    super.dispose();
  }

  int _telemetryStatus() {
    final t = _state?.shuntUpdated;
    if (t == null) return 2;
    final age = DateTime.now().difference(t).inSeconds;
    if (age <= 5) return 0;
    if (age <= 15) return 1;
    return 2;
  }

  bool _shuntFresh() {
    final t = _state?.shuntUpdated;
    if (t == null) return false;
    return DateTime.now().difference(t).inSeconds <= 5;
  }

  @override
  Widget build(BuildContext context) {
    final shunt = _state?.shunt;
    final hasData = shunt != null;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      _telemetryDot(),
                      const SizedBox(width: 8),
                      const Text('VAGNKOLL JBD',
                          style: TextStyle(
                            letterSpacing: 4,
                            fontSize: 14,
                            color: Color(0xFF6B7280),
                          )),
                    ],
                  ),
                  Row(
                    children: [
                      Text('v${_shortBuildId()}',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF4B5563))),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.electrical_services, size: 22),
                        color: const Color(0xFF6B7280),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: _openAppliances,
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.show_chart, size: 22),
                        color: const Color(0xFF6B7280),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: hasData ? _openHistory : null,
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.settings, size: 22),
                        color: const Color(0xFF6B7280),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: _openSetup,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(child: !hasData ? _waitingView() : _liveView(shunt)),
            ],
          ),
        ),
      ),
    );
  }

  void _openHistory() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HistoryScreen(store: _history),
    ));
  }

  String _shortBuildId() {
    final dash = kBuildId.indexOf('-');
    return dash > 0 ? kBuildId.substring(0, dash) : kBuildId;
  }

  void _openSetup() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SetupScreen(
        pauseHooks: [
          () async => _scanner.stop(),
          _energy.pause,
          _history.pause,
          _pauseTelemetryTimer,
        ],
        resumeHooks: [
          () async => _scanner.start(),
          _energy.resume,
          _history.resume,
          _resumeTelemetryTimer,
        ],
        onConfigSaved: _onConfigSaved,
      ),
    ));
  }

  void _onConfigSaved() {
    AppConfig.load().then((cfg) {
      if (!mounted) return;
      setState(() => _config = cfg);
      _scanner.updateDevices(cfg.devices);
      _alarms.updateConfig(cfg);
      _webServer?.updateConfig(cfg);
    });
  }

  void _openAppliances() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AppliancesScreen(
        store: _appliances,
        scanner: _scanner,
        classifier: _classifier,
        pauseHooks: [
          _energy.pause,
          _history.pause,
          _pauseTelemetryTimer,
        ],
        resumeHooks: [
          _energy.resume,
          _history.resume,
          _resumeTelemetryTimer,
        ],
      ),
    ));
  }

  void _pauseTelemetryTimer() => _telemetryTimer?.cancel();

  void _resumeTelemetryTimer() {
    _telemetryTimer?.cancel();
    _telemetryTimer =
        Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Widget _waitingView() {
    if (_config.devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bluetooth_disabled,
                size: 56, color: Color(0xFF4B5563)),
            const SizedBox(height: 20),
            const Text('Inget JBD BMS konfigurerat',
                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 15)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _openSetup,
              icon: const Icon(Icons.settings),
              label: const Text('Öppna setup'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1F2937),
                foregroundColor: const Color(0xFF4ADE80),
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
            ),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Color(0xFF4ADE80)),
          const SizedBox(height: 24),
          Text(_status,
              style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 16)),
        ],
      ),
    );
  }

  Widget _liveView(shunt) {
    final voltage = shunt?.batteryVoltage as double?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BigStat(
          label: 'BATTERI',
          labelColor: _shuntFresh()
              ? const Color(0xFF4ADE80)
              : const Color(0xFF6B7280),
          value: shunt?.soc.toStringAsFixed(1) ?? '—',
          unit: '%',
          color: _socColor(shunt?.soc as double?),
          rightLines: shunt == null
              ? null
              : [
                  '${shunt.batteryVoltage.toStringAsFixed(2)} V',
                  '${shunt.current >= 0 ? "+" : ""}${shunt.current.toStringAsFixed(2)} A',
                  '${(_config.batteryCapacityAh * shunt.soc / 100).toStringAsFixed(1)} Ah kvar',
                ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _SmallStat(
                label: 'Laddat idag',
                value: _energy.solarAhToday.toStringAsFixed(1),
                unit: 'Ah',
                color: const Color(0xFF4ADE80),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SmallStat(
                label: 'Använt idag',
                value: _energy.usedAhToday.toStringAsFixed(1),
                unit: 'Ah',
                color: const Color(0xFFEF4444),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _SmallStat(
                label: 'Förbrukning',
                value: voltage != null && shunt != null
                    ? '${shunt.current.abs().toStringAsFixed(1)}A / ${(shunt.current.abs() * voltage).toStringAsFixed(0)}W'
                    : '—',
                unit: '',
                color: const Color(0xFFEF4444),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SmallStat(
                label: 'Ah kvar (BMS)',
                value: shunt?.consumedAh != null
                    ? (_config.batteryCapacityAh + shunt!.consumedAh!)
                        .toStringAsFixed(1)
                    : '—',
                unit: 'Ah',
                color: _socColor(shunt?.soc as double?),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ..._activeAlarms.map(_alarmBanner),
        if (_classification != null &&
            _classification!.activeAppliances.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Aktivt nu: ${_classification!.activeAppliances.map((a) => a.name).join(", ")}',
              style:
                  const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
            ),
          ),
        const Spacer(),
        if (_webServer?.ipAddress != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Webb: http://${_webServer!.ipAddress}:${WebServer.port}',
              style: const TextStyle(
                  color: Color(0xFF6B7280), fontSize: 11),
            ),
          ),
      ],
    );
  }

  Color _socColor(double? soc) {
    if (soc == null) return const Color(0xFF9CA3AF);
    if (soc < _config.socCritical) return const Color(0xFFEF4444);
    if (soc < _config.socWarn) return const Color(0xFFFBBF24);
    return const Color(0xFF4ADE80);
  }

  Widget _telemetryDot() {
    final status = _telemetryStatus();
    final color = switch (status) {
      0 => const Color(0xFF4ADE80),
      1 => const Color(0xFFFBBF24),
      _ => const Color(0xFFEF4444),
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _alarmBanner(Alarm a) {
    final c = switch (a.level) {
      AlarmLevel.emergency => const Color(0xFFEF4444),
      AlarmLevel.critical  => const Color(0xFFEF4444),
      AlarmLevel.warn      => const Color(0xFFFBBF24),
      AlarmLevel.info      => const Color(0xFF4ADE80),
    };
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.withOpacity(0.15),
        border: Border.all(color: c, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(a.message, style: TextStyle(color: c, fontSize: 13)),
    );
  }
}

class _BigStat extends StatelessWidget {
  final String label, value, unit;
  final Color color;
  final Color? labelColor;
  final List<String>? rightLines;
  const _BigStat({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    this.labelColor,
    this.rightLines,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: labelColor ?? const Color(0xFF6B7280),
                  letterSpacing: 2,
                  fontSize: 11)),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(value,
                      style: TextStyle(
                          fontSize: 56,
                          fontWeight: FontWeight.w200,
                          color: color,
                          height: 1.0)),
                  const SizedBox(width: 6),
                  Text(unit,
                      style: TextStyle(
                          fontSize: 22, color: color.withOpacity(0.7))),
                ],
              ),
              if (rightLines != null)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: rightLines!
                          .map((line) => Text(line,
                              style: TextStyle(
                                fontSize: 14,
                                color: color.withOpacity(0.85),
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              )))
                          .toList(),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SmallStat extends StatelessWidget {
  final String label, value, unit;
  final Color? color;
  final Color? labelColor;
  const _SmallStat(
      {required this.label,
      required this.value,
      required this.unit,
      this.color,
      this.labelColor});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.white;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: labelColor ?? const Color(0xFF6B7280),
                  letterSpacing: 1,
                  fontSize: 10)),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w300,
                      color: c,
                      height: 1.0)),
              const SizedBox(width: 4),
              Text(unit,
                  style: TextStyle(
                      fontSize: 12, color: c.withOpacity(0.7))),
            ],
          ),
        ],
      ),
    );
  }
}
