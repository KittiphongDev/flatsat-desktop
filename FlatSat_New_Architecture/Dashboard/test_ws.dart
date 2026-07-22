import 'dart:convert';
import 'dart:io';

void main() async {
  print('Connecting to ws://127.0.0.1:8080...');
  try {
    final socket = await WebSocket.connect('ws://127.0.0.1:8080');
    print('Connected!');
    socket.listen(
      (data) {
        print('Received data type: ${data.runtimeType}');
        print('Received: $data');
      },
      onError: (err) => print('Error: $err'),
      onDone: () => print('Done.'),
    );
  } catch (e) {
    print('Exception: $e');
  }
}
