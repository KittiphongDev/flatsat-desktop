import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Appends EPS records (from a live snapshot or a pulled satellite log) to a
/// CSV on this PC so history survives restarts. Returns the file path.
///
/// Each record is a map: {t, ina226:[{voltage,current}], tmp102:[{temperature}],
/// adm1177:[{voltage_mv,current_ma}]}.
Future<String?> appendEpsHistory(List records) async {
  if (records.isEmpty) return null;
  try {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/eps_history.csv');
    final existed = await file.exists();

    final sb = StringBuffer();
    if (!existed) {
      final header = <String>['timestamp'];
      for (var i = 0; i < 6; i++) {
        header..add('ina${i}_v')..add('ina${i}_a');
      }
      for (var i = 0; i < 2; i++) {
        header.add('tmp${i}_c');
      }
      for (var i = 0; i < 4; i++) {
        header..add('adm${i}_mv')..add('adm${i}_ma');
      }
      sb.writeln(header.join(','));
    }

    for (final r in records) {
      final row = <String>['${r['t'] ?? 0}'];
      final ina = (r['ina226'] as List?) ?? [];
      for (final e in ina) {
        row..add('${e['voltage']}')..add('${e['current']}');
      }
      final tmp = (r['tmp102'] as List?) ?? [];
      for (final e in tmp) {
        row.add('${e['temperature']}');
      }
      final adm = (r['adm1177'] as List?) ?? [];
      for (final e in adm) {
        row..add('${e['voltage_mv']}')..add('${e['current_ma']}');
      }
      sb.writeln(row.join(','));
    }

    await file.writeAsString(sb.toString(), mode: FileMode.append, flush: true);
    return file.path;
  } catch (_) {
    return null;
  }
}
