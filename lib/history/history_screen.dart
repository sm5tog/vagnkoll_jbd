import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'history_store.dart';

enum HistoryWindow { hour, day, week }

extension on HistoryWindow {
  String get label => switch (this) {
        HistoryWindow.hour => '1 tim',
        HistoryWindow.day => '24 tim',
        HistoryWindow.week => '7 dygn',
      };
  Duration get duration => switch (this) {
        HistoryWindow.hour => const Duration(hours: 1),
        HistoryWindow.day => const Duration(hours: 24),
        HistoryWindow.week => const Duration(days: 7),
      };
}

class HistoryScreen extends StatefulWidget {
  final HistoryStore store;
  const HistoryScreen({super.key, required this.store});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  HistoryWindow _window = HistoryWindow.day;
  List<HistoryPoint> _points = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await widget.store.read(window: _window.duration);
    if (!mounted) return;
    setState(() {
      _points = data;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Historik'),
        backgroundColor: const Color(0xFF111827),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<HistoryWindow>(
              segments: HistoryWindow.values
                  .map((w) => ButtonSegment(value: w, label: Text(w.label)))
                  .toList(),
              selected: {_window},
              onSelectionChanged: (s) {
                setState(() => _window = s.first);
                _load();
              },
            ),
          ),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_points.isEmpty)
            const Expanded(
              child: Center(
                child: Text(
                  'Ingen historik ännu — vänta några minuter.',
                  style: TextStyle(color: Color(0xFF9CA3AF)),
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _ChartCard(
                    title: 'Batteri (%)',
                    color: const Color(0xFF4ADE80),
                    points: _points,
                    yOf: (p) => p.soc,
                    yMin: 0,
                    yMax: 100,
                  ),
                  _ChartCard(
                    title: 'Spänning (V)',
                    color: Colors.white,
                    points: _points,
                    yOf: (p) => p.voltage,
                  ),
                  _ChartCard(
                    title: 'Ström (A)',
                    color: const Color(0xFFFBBF24),
                    points: _points,
                    yOf: (p) => p.current,
                  ),
                  _ChartCard(
                    title: 'Sol (W)',
                    color: const Color(0xFFFBBF24),
                    points: _points,
                    yOf: (p) => p.solarPower,
                    yMin: 0,
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  final String title;
  final Color color;
  final List<HistoryPoint> points;
  final double? Function(HistoryPoint) yOf;
  final double? yMin;
  final double? yMax;

  const _ChartCard({
    required this.title,
    required this.color,
    required this.points,
    required this.yOf,
    this.yMin,
    this.yMax,
  });

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    for (final p in points) {
      final y = yOf(p);
      if (y != null) {
        spots.add(FlSpot(
          p.time.millisecondsSinceEpoch.toDouble(),
          y,
        ));
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                color: Color(0xFF9CA3AF),
                fontSize: 12,
                letterSpacing: 1,
              )),
          const SizedBox(height: 12),
          SizedBox(
            height: 140,
            child: spots.isEmpty
                ? const Center(
                    child: Text('—',
                        style: TextStyle(color: Color(0xFF4B5563))))
                : LineChart(
                    LineChartData(
                      minY: yMin,
                      maxY: yMax,
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          color: color,
                          barWidth: 2,
                          isCurved: false,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            color: color.withOpacity(0.1),
                          ),
                        ),
                      ],
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(),
                        rightTitles: const AxisTitles(),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 40,
                            getTitlesWidget: (v, m) => Text(
                              v.toStringAsFixed(0),
                              style: const TextStyle(
                                color: Color(0xFF6B7280),
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
                            getTitlesWidget: (v, m) {
                              final dt = DateTime.fromMillisecondsSinceEpoch(
                                  v.toInt());
                              final fmt = points.length > 1 &&
                                      points.last.time
                                              .difference(points.first.time)
                                              .inHours >
                                          24
                                  ? DateFormat('d/M')
                                  : DateFormat('HH:mm');
                              return Text(
                                fmt.format(dt),
                                style: const TextStyle(
                                  color: Color(0xFF6B7280),
                                  fontSize: 10,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (v) => FlLine(
                          color: const Color(0xFF1F2937),
                          strokeWidth: 1,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
