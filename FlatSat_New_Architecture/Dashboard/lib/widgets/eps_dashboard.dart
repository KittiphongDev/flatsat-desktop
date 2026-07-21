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

  // Channel names + I2C addresses from the FlatSat EPS documentation.
  static const List<String> inaNames = [
    'Solar Cell 1',
    'Solar Cell 2',
    'Solar Cell 3',
    'Solar Cell 4',
    'Battery Charging',
    'Battery Discharging',
  ];
  static const List<String> inaAddr = ['0x40', '0x41', '0x42', '0x43', '0x47', '0x48'];

  static const List<String> admNames = [
    'OBC Power',
    'Communication Power',
    'Payload 1 Power',
    'Payload 2 Power',
  ];
  static const List<String> admAddr = ['0x58', '0x59', '0x5A', '0x5B'];

  static const List<String> tmpNames = ['Battery 1 Temp', 'Battery 2 Temp'];
  static const List<String> tmpAddr = ['0x4A', '0x4B'];

  static String _name(List<String> names, int i) =>
      (i >= 0 && i < names.length) ? names[i] : 'Channel $i';
  static String _addr(List<String> addrs, int i) =>
      (i >= 0 && i < addrs.length) ? addrs[i] : '--';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ws = context.watch<WebSocketService>();
    final eps = ws.lastEps;
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

          if (ws.epsReceiving) ...[
            _transferBar(context, ws),
            const SizedBox(height: 16),
          ],

          if (eps == null && !ws.epsReceiving)
            _awaiting(context)
          else if (eps != null) ...[
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
                  title: _name(inaNames, r.index),
                  subtitle: 'INA226 · ${_addr(inaAddr, r.index)}',
                  chip: 'CH ${r.index}',
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
                  title: _name(tmpNames, r.index),
                  subtitle: 'TMP102 · ${_addr(tmpAddr, r.index)}',
                  chip: 'CH ${r.index}',
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
                  title: _name(admNames, r.index),
                  subtitle: 'ADM1177 · ${_addr(admAddr, r.index)}'
                      '${r.index == 0 ? ' · locked' : ''}',
                  chip: 'CH ${r.index}',
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
          ], // end else (eps != null)
        ],
      ),
    );
  }

  Widget _transferBar(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    final pct = ws.epsProgress.clamp(0, 100);
    final total = ws.epsChunksTotal;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.accent.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.accent.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(c.accent),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Receiving EPS telemetry…',
                style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                total > 0
                    ? '$pct%  (${ws.epsChunksReceived}/$total)'
                    : '$pct%',
                style: TextStyle(
                    color: c.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct / 100.0,
              minHeight: 5,
              backgroundColor: c.border,
              valueColor: AlwaysStoppedAnimation(c.accent),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.download_rounded, size: 12, color: c.textMuted),
              const SizedBox(width: 4),
              Text(
                _fmtSpeed(ws.epsSpeedBps),
                style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 10,
                    fontFamily: 'monospace'),
              ),
              const Spacer(),
              Text(
                '${ws.epsBytes} B received',
                style: TextStyle(
                    color: c.textMuted,
                    fontSize: 10,
                    fontFamily: 'monospace'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmtSpeed(double bps) {
    if (bps <= 0) return '—';
    if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    return '${bps.toStringAsFixed(0)} B/s';
  }

  Widget _awaiting(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        children: [
          Icon(Icons.hourglass_empty, color: c.textMuted, size: 28),
          const SizedBox(height: 10),
          Text(
            'No EPS data received yet',
            style: TextStyle(
                color: c.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Press GET EPS. The panel fills in once the satellite responds.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _statsStrip(BuildContext context, WebSocketService ws, EpsData? eps) {
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
          stat(
            'UPDATED',
            ws.lastEpsTime == null
                ? '— no data'
                : '${_fmtTime(ws.lastEpsTime!)} · ${_ageStr(ws.lastEpsTime!)}',
            ws.lastEpsTime == null ? c.warning : c.success,
          ),
          stat('PACKETS', '${ws.epsPacketCount}', c.accent),
          stat('SAMPLES', '${ws.epsHistory.length}', c.info),
          if (eps != null) stat('INA226', '${eps.ina226.length}', c.textSecondary),
          if (eps != null) stat('TMP102', '${eps.tmp102.length}', c.textSecondary),
          if (eps != null)
            stat('ADM1177', '${eps.adm1177.length}', c.textSecondary),
        ],
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmtTime(DateTime t) =>
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  static String _ageStr(DateTime t) {
    final s = DateTime.now().difference(t).inSeconds;
    if (s < 1) return 'just now';
    if (s < 60) return '${s}s ago';
    final m = s ~/ 60;
    if (m < 60) return '${m}m ago';
    return '${m ~/ 60}h ago';
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
  final String subtitle;
  final String chip;
  final List<_Metric>? rows;
  final _Metric? big;

  const _SensorCard({
    required this.title,
    required this.subtitle,
    required this.chip,
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
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 6),
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
          Text(subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: c.textMuted, fontSize: 10, fontFamily: 'monospace')),
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
