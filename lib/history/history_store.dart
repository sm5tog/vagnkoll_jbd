import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../victron/victron_scanner.dart';

class HistoryPoint {
  final DateTime time;
  final double? soc;
  final double? voltage;
  final double? current;
  final double? solarPower;

  HistoryPoint({
    required this.time,
    this.soc,
    this.voltage,
    this.current,
    this.solarPower,
  });
}

/// Loggar mätvärden till SQLite. Sparar en sample per ~10 sekunder.
/// Äldre data tunnas ut automatiskt (en sample per minut för > 24h, en per
/// timme för > 7 dygn) för att hålla databasen liten.
class HistoryStore {
  static const _sampleIntervalSec = 10;
  static const _thinFirstAfterHours = 24;
  static const _thinSecondAfterDays = 7;

  Database? _db;
  Timer? _sampleTimer;
  Timer? _thinTimer;
  VictronScanner? _scanner;
  bool _paused = false;
  void pause() => _paused = true;
  void resume() => _paused = false;

  Future<void> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'vagnkoll.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE history (
            ts INTEGER PRIMARY KEY,
            soc REAL,
            voltage REAL,
            current REAL,
            solar_w REAL
          )
        ''');
        await db.execute('CREATE INDEX idx_history_ts ON history(ts)');
      },
    );
  }

  void attachScanner(VictronScanner scanner) {
    _scanner = scanner;
    _sampleTimer?.cancel();
    _sampleTimer = Timer.periodic(
      const Duration(seconds: _sampleIntervalSec),
      (_) => _writeSample(),
    );
    _thinTimer?.cancel();
    _thinTimer = Timer.periodic(const Duration(hours: 1), (_) => _thin());
  }

  Future<void> _writeSample() async {
    if (_paused) return;
    final s = _scanner?.current;
    if (s == null) return;
    if (s.shunt == null && s.solar == null) return;
    final db = _db;
    if (db == null) return;

    final voltage = s.shunt?.batteryVoltage ?? s.solar?.batteryVoltage;
    await db.insert(
      'history',
      {
        'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'soc': _safe(s.shunt?.soc),
        'voltage': _safe(voltage),
        'current': _safe(s.shunt?.current),
        'solar_w': _safe(s.solar?.pvPower),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  double? _safe(double? v) => (v == null || v.isNaN) ? null : v;

  Future<void> _thin() async {
    final db = _db;
    if (db == null) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Lager 1: data äldre än 24h → behåll endast en sample per minut
    final cutoff1 = now - _thinFirstAfterHours * 3600;
    await db.rawDelete('''
      DELETE FROM history
      WHERE ts < ?
        AND ts NOT IN (
          SELECT MIN(ts) FROM history
          WHERE ts < ?
          GROUP BY ts / 60
        )
    ''', [cutoff1, cutoff1]);

    // Lager 2: data äldre än 7 dygn → behåll endast en per timme
    final cutoff2 = now - _thinSecondAfterDays * 86400;
    await db.rawDelete('''
      DELETE FROM history
      WHERE ts < ?
        AND ts NOT IN (
          SELECT MIN(ts) FROM history
          WHERE ts < ?
          GROUP BY ts / 3600
        )
    ''', [cutoff2, cutoff2]);
  }

  Future<List<HistoryPoint>> read({required Duration window}) async {
    final db = _db;
    if (db == null) return [];
    final from = DateTime.now().subtract(window).millisecondsSinceEpoch ~/ 1000;
    final rows = await db.query(
      'history',
      where: 'ts >= ?',
      whereArgs: [from],
      orderBy: 'ts ASC',
    );
    return rows
        .map((r) => HistoryPoint(
              time: DateTime.fromMillisecondsSinceEpoch((r['ts'] as int) * 1000),
              soc: r['soc'] as double?,
              voltage: r['voltage'] as double?,
              current: r['current'] as double?,
              solarPower: r['solar_w'] as double?,
            ))
        .toList();
  }

  Future<void> close() async {
    _sampleTimer?.cancel();
    _thinTimer?.cancel();
    await _db?.close();
  }
}
