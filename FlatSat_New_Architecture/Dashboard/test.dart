import 'dart:io';
void main() async {
  print('CWD: ${Directory.current.path}');
  final f = File('../PC_Bridge/gs_bridge.py');
  print('Exists? ${f.existsSync()}');
}
