import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';
import '../services/websocket_service.dart';
import '../models/telemetry_data.dart';
import '../theme/app_theme.dart';

/// A rich EPS dashboard: per-channel sensor cards grouped by device, plus live
/// line charts, all driven by the current app theme.
class EpsDashboard extends StatelessWidget {
  const EpsDashboard({super.key});

  // Channel names from the FlatSat EPS documentation.
  static const List<String> inaNames = [
    'Solar Input 1',
    'Solar Input 2',
    'Solar Input 3',
    'Solar Input 4',
    'Battery Charge',
    'Battery Discharge',
  ];
  static const List<String> admNames = [
    'OBC (locked)',
    'Communication',
    'Payload 1 / GPS',
    'Payload 2 / PC104',
  ];
  static const List<String> tmpNames = ['Battery 1', 'Battery 2'];

  static String _name(List<String> names, int i) =>
      (i >= 0 && i < names.length) ? names[i] : 'Channel $i';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ws = context.watch<WebSocketService>();
    final eps = ws.lastEps;

    if (eps == null) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border),
        ),
        child: Center(
          child: Text(
            'No EPS data yet. Press GET EPS to read the power system.',
            style: TextStyle(color: c.textMuted, fontSize: 13),
          ),
        ),
      );
    }

    final history = ws.epsHistory;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _statsStrip(context, ws, eps),
          const SizedBox(height: 18),

          // ---- INA226 ----
          _groupHeader(context, Icons.bolt, 'INA226 · Solar & Battery Monitors',
              '${eps.ina226.length} channels'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final r in eps.ina226)
                _SensorCard(
                  title: 'INA226',
                  chip: 'CH ${r.index}',
                  name: _name(inaNames, r.index),
                  rows: [
                    _Metric('Bus Voltage', 'V', r.voltage.toStringAsFixed(3),
                        c.info),
                    _Metric('Current', 'A', r.current.toStringAsFixed(3),
                        c.success),
                    _Metric('Power', 'W', r.power.toStringAsFixed(2), c.accent),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _ChartCard(
                  title: 'BUS VOLTAGE',
                  unit: 'V',
                  history: history,
                  channelCount: eps.ina226.length,
                  value: (e, ch) =>
                      ch < e.ina226.length ? e.ina226[ch].voltage : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ChartCard(
                  title: 'CURRENT',
                  unit: 'A',
                  history: history,
                  channelCount: eps.ina226.length,
                  value: (e, ch) =>
                      ch < e.ina226.length ? e.ina226[ch].current : null,
                ),
              ),
            ],
          ),

          const SizedBox(height: 22),

          // ---- TMP102 ----
          _groupHeader(context, Icons.thermostat,
              'TMP102 · Battery Temperatures', '${eps.tmp102.length} sensors'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final r in eps.tmp102)
                _SensorCard(
                  title: 'TMP102',
                  chip: 'CH ${r.index}',
                  name: _name(tmpNames, r.index),
                  big: _Metric('Temperature', '°C',
                      r.temperature.toStringAsFixed(2), c.warning),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _ChartCard(
            title: 'TEMPERATURE',
            unit: '°C',
            history: history,
            channelCount: eps.tmp102.length,
            value: (e, ch) =>
                ch < e.tmp102.length ? e.tmp102[ch].temperature : null,
          ),

          const SizedBox(height: 22),

          // ---- ADM1177 ----
          _groupHeader(context, Icons.developer_board,
              'ADM1177 · Power Output Channels', '${eps.adm1177.length} outputs'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final r in eps.adm1177)
                _SensorCard(
                  title: 'ADM1177',
                  chip: 'CH ${r.index}',
                  name: _name(admNames, r.index),
                  rows: [
                    _Metric('Voltage', 'V',
                        (r.voltageMv / 1000).toStringAsFixed(2), c.info),
                    _Metric('Current', 'mA', '${r.currentMa}', c.success),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          _ChartCard(
            title: 'OUTPUT VOLTAGE',
            unit: 'V',
            history: history,
            channelCount: eps.adm1177.length,
            value: (e, ch) =>
                ch < e.adm1177.length ? e.adm1177[ch].voltageMv / 1000 : null,
          ),
        ],
      ),
    );
  }

  Widget _statsStrip(BuildContext context, WebSocketService ws, EpsData eps) {
    final c = context.colors;
    Widget stat(String label, String value, Color color) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$label ',
                style: TextStyle(
                    color: c.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1)),
            Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace')),
          ],
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.scaffold,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Wrap(
        spacing: 20,
        runSpacing: 6,
        children: [
          stat('PACKETS', '${ws.epsPacketCount}', c.accent),
          stat('SAMPLES', '${ws.epsHistory.length}', c.info),
          stat('INA226', '${eps.ina226.length}', c.textSecondary),
          stat('TMP102', '${eps.tmp102.length}', c.textSecondary),
          stat('ADM1177', '${eps.adm1177.length}', c.textSecondary),
        ],
      ),
    );
  }

  Widget _groupHeader(
      BuildContext context, IconData icon, String title, String count) {
    final c = context.colors;
    return Row(
      children: [
        Icon(icon, color: c.accent, size: 16),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: c.scaffold,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.border),
          ),
          child: Text(count,
              style: TextStyle(color: c.textMuted, fontSize: 10)),
        ),
      ],
    );
  }
}

/// Colors used to distinguish chart channels.
List<Color> _chartColors(AppColors c) =>
    [c.accent, c.info, c.success, c.warning, c.secondary, c.pink];

class _Metric {
  final String label;
  final String unit;
  final String value;
  final Color color;
  _Metric(this.label, this.unit, this.value, this.color);
}

class _SensorCard extends StatelessWidget {
  final String title;
  final String chip;
  final String name;
  final List<_Metric>? rows;
  final _Metric? big;

  const _SensorCard({
    required this.title,
    required this.chip,
    required this.name,
    this.rows,
    this.big,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 220,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.scaffold,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title,
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: c.accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(chip,
                    style: TextStyle(
                        color: c.accent,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.textMuted, fontSize: 10)),
          const SizedBox(height: 10),
          if (big != null)
            Center(
              child: Column(
                children: [
                  Text('${big!.value} ${big!.unit}',
                      style: TextStyle(
                          color: big!.color,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'monospace')),
                  const SizedBox(height: 2),
                  Text(big!.label,
                      style: TextStyle(color: c.textMuted, fontSize: 10)),
                ],
              ),
            ),
          if (rows != null)
            for (final m in rows!)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Text(m.label,
                        style: TextStyle(color: c.textSecondary, fontSize: 11)),
                    Text('  (${m.unit})',
                        style: TextStyle(color: c.textMuted, fontSize: 9)),
                    const Spacer(),
                    Text(m.value,
                        style: TextStyle(
                            color: m.color,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace')),
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
  final String unit;
  final List<EpsData> history;
  final int channelCount;
  final double? Function(EpsData e, int ch) value;

  const _ChartCard({
    required this.title,
    required this.unit,
    required this.history,
    required this.channelCount,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final colors = _chartColors(c);

    final bars = <LineChartBarData>[];
    double? minY, maxY;
    for (var ch = 0; ch < channelCount; ch++) {
      final spots = <FlSpot>[];
      for (var i = 0; i < history.length; i++) {
        final v = value(history[i], ch);
        if (v == null || v.isNaN || v.isInfinite) continue;
        spots.add(FlSpot(i.toDouble(), v));
        if (minY == null || v < minY) minY = v;
        if (maxY == null || v > maxY) maxY = v;
      }
      if (spots.isEmpty) continue;
      bars.add(LineChartBarData(
        spots: spots,
        isCurved: true,
        curveSmoothness: 0.2,
        color: colors[ch % colors.length],
        barWidth: 2,
        dotData: const FlDotData(show: false),
      ));
    }

    minY ??= 0;
    maxY ??= 1;
    if (minY == maxY) {
      minY = minY - 1;
      maxY = maxY + 1;
    }
    final pad = (maxY - minY) * 0.15;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.scaffold,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title,
                  style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1)),
              const SizedBox(width: 8),
              Text('($unit)',
                  style: TextStyle(color: c.textMuted, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 8),
          // Legend
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              for (var ch = 0; ch < channelCount; ch++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors[ch % colors.length],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text('CH $ch',
                        style: TextStyle(color: c.textMuted, fontSize: 9)),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 130,
            child: bars.isEmpty
                ? Center(
                    child: Text('Collecting…',
                        style: TextStyle(color: c.textMuted, fontSize: 11)),
                  )
                : LineChart(
                    LineChartData(
                      minY: minY - pad,
                      maxY: maxY + pad,
                      lineBarsData: bars,
                      lineTouchData: LineTouchData(enabled: false),
                      titlesData: FlTitlesData(
                        topTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        rightTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 40,
                            getTitlesWidget: (v, meta) => Text(
                              v.toStringAsFixed(2),
                              style:
                                  TextStyle(color: c.textMuted, fontSize: 8),
                            ),
                          ),
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (v) =>
                            FlLine(color: c.border, strokeWidth: 1),
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
