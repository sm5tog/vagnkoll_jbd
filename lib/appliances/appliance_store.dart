import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

enum ApplianceCategory {
  load,     // vanlig last (lampor, pump, fläkt)
  friendly, // ofarlig glädje (kaffe)
  warn,     // bör inte vara på (golvvärme, kylskåp på 230V)
}

/// Enkel tröskel-baserad apparatprofil.
/// Apparaten räknas som aktiv när total last matchar [expectedWatts]
/// ±[tolerancePct]% under minst [minDurationSec] sekunder.
class Appliance {
  final int? id;
  final String name;
  final ApplianceCategory category;
  final double expectedWatts;
  final double tolerancePct;
  final String? customMessage;
  final int minDurationSec;
  final DateTime createdAt;

  Appliance({
    this.id,
    required this.name,
    required this.category,
    required this.expectedWatts,
    this.tolerancePct = 10.0,
    this.customMessage,
    this.minDurationSec = 5,
    required this.createdAt,
  });

  double get toleranceWatts => expectedWatts * tolerancePct / 100;
  double get lowerBound => expectedWatts - toleranceWatts;
  double get upperBound => expectedWatts + toleranceWatts;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'category': category.name,
        'expected_watts': expectedWatts,
        'tolerance_pct': tolerancePct,
        'custom_message': customMessage,
        'min_duration_sec': minDurationSec,
        'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
      };

  static Appliance fromMap(Map<String, dynamic> m) => Appliance(
        id: m['id'] as int?,
        name: m['name'] as String,
        category: ApplianceCategory.values.firstWhere(
          (c) => c.name == m['category'],
          orElse: () => ApplianceCategory.load,
        ),
        expectedWatts: (m['expected_watts'] as num).toDouble(),
        tolerancePct: (m['tolerance_pct'] as num?)?.toDouble() ?? 10.0,
        customMessage: m['custom_message'] as String?,
        minDurationSec: m['min_duration_sec'] as int? ?? 5,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (m['created_at'] as int) * 1000),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category.name,
        'expected_watts': expectedWatts,
        'tolerance_pct': tolerancePct,
        'custom_message': customMessage,
        'min_duration_sec': minDurationSec,
        'created_at': createdAt.toIso8601String(),
      };
}

class ApplianceStore {
  Database? _db;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  Future<void> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'appliances.db');
    _db = await openDatabase(
      path,
      version: 4,
      onCreate: (db, v) async {
        await _createTable(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 4) {
          await db.execute('DROP TABLE IF EXISTS appliances');
          await _createTable(db);
        }
      },
    );
  }

  Future<void> _createTable(Database db) async {
    await db.execute('''
      CREATE TABLE appliances (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        category TEXT NOT NULL,
        expected_watts REAL NOT NULL,
        tolerance_pct REAL NOT NULL DEFAULT 10.0,
        custom_message TEXT,
        min_duration_sec INTEGER NOT NULL DEFAULT 5,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  Future<List<Appliance>> all() async {
    final db = _db;
    if (db == null) return [];
    final rows = await db.query('appliances', orderBy: 'expected_watts ASC');
    return rows.map(Appliance.fromMap).toList();
  }

  Future<int> insert(Appliance a) async {
    final db = _db;
    if (db == null) return -1;
    final id = await db.insert(
      'appliances',
      a.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _changes.add(null);
    return id;
  }

  Future<void> update(int id, Appliance a) async {
    final db = _db;
    if (db == null) return;
    await db.update(
      'appliances',
      a.toMap()..remove('id'),
      where: 'id = ?',
      whereArgs: [id],
    );
    _changes.add(null);
  }

  Future<void> delete(int id) async {
    await _db?.delete('appliances', where: 'id = ?', whereArgs: [id]);
    _changes.add(null);
  }

  Future<String> exportJson() async {
    final list = await all();
    return const JsonEncoder.withIndent('  ')
        .convert(list.map((a) => a.toJson()).toList());
  }

  Future<int> importJson(String jsonStr) async {
    final list = jsonDecode(jsonStr) as List;
    var n = 0;
    for (final m in list) {
      final mm = m as Map<String, dynamic>;
      await insert(Appliance(
        name: mm['name'] as String,
        category: ApplianceCategory.values.firstWhere(
          (c) => c.name == mm['category'],
          orElse: () => ApplianceCategory.load,
        ),
        expectedWatts: (mm['expected_watts'] as num).toDouble(),
        tolerancePct: (mm['tolerance_pct'] as num?)?.toDouble() ?? 10.0,
        customMessage: mm['custom_message'] as String?,
        minDurationSec: mm['min_duration_sec'] as int? ?? 5,
        createdAt: DateTime.tryParse(mm['created_at'] as String) ?? DateTime.now(),
      ));
      n++;
    }
    return n;
  }

  Future<void> close() async {
    await _db?.close();
    await _changes.close();
  }
}
