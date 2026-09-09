// Verifica el contrato REST + WS de OmarchyLink (integración OhmLauncher <->
// Omarchy) contra un HttpServer real en loopback: clipboard, navegación y
// descarga de archivos, y eventos de control remoto (input) por REST y por
// WebSocket.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ohm_launcher/parts/omarchy_link.dart';

void main() {
  late HttpServer server;
  late int port;
  late String clipText;
  late List<Map<String, dynamic>> inputEvents;
  late Directory tmpRoot;
  late OmarchyLink link;

  Future<void> route(HttpRequest req) async {
    if (req.uri.path == '/omarchy/ws') {
      await link.handleWs(req);
    } else {
      await link.handleRest(req);
    }
  }

  setUp(() async {
    clipText = '';
    inputEvents = [];
    tmpRoot = await Directory.systemTemp.createTemp('ohm_link_test');
    await File('${tmpRoot.path}/hola.txt').writeAsString('contenido ohm');
    await Directory('${tmpRoot.path}/sub').create();

    link = OmarchyLink(
      onDiscover: () async => {'name': 'TestPhone', 'port': 0},
      onClipboardGet: () async => clipText,
      onClipboardSet: (t) async => clipText = t,
      onFilesList: (path) async {
        final dir = Directory(path);
        if (!await dir.exists()) {
          return {'error': 'not_found', 'path': path, 'entries': <dynamic>[]};
        }
        final entries = <Map<String, dynamic>>[];
        await for (final e in dir.list(followLinks: false)) {
          entries.add({
            'name': e.path.split('/').last,
            'path': e.path,
            'isDir': e is Directory,
          });
        }
        return {'path': path, 'parent': '', 'entries': entries};
      },
      onFileSend: (path) async {
        final f = File(path);
        if (!await f.exists()) return <int>[];
        return f.readAsBytes();
      },
      onInputEvent: (ev) async {
        inputEvents.add(ev);
        return {'ok': true, 'action': ev['action']};
      },
    );

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.forEach(route);
  });

  tearDown(() async {
    link.dispose();
    await server.close(force: true);
    await tmpRoot.delete(recursive: true);
  });

  Future<HttpClientResponse> req(String method, String path,
      {Map<String, dynamic>? body}) async {
    final client = HttpClient();
    final r = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      r.headers.contentType = ContentType.json;
      r.contentLength = bytes.length;
      r.add(bytes);
    }
    final resp = await r.close();
    client.close();
    return resp;
  }

  test('clipboard round-trip GET/PUT', () async {
    final put = await req('PUT', '/omarchy/clipboard', body: {'text': 'hola pc'});
    expect(put.statusCode, 200);
    await utf8.decoder.bind(put).join();

    final get = await req('GET', '/omarchy/clipboard');
    final data = jsonDecode(await utf8.decoder.bind(get).join());
    expect(data['text'], 'hola pc');
    expect(clipText, 'hola pc');
  });

  test('files listing devuelve entradas con nombre y tipo', () async {
    final resp = await req('GET', '/omarchy/files?path=${Uri.encodeComponent(tmpRoot.path)}');
    expect(resp.statusCode, 200);
    final data = jsonDecode(await utf8.decoder.bind(resp).join());
    expect(data['path'], tmpRoot.path);
    final names = (data['entries'] as List).map((e) => e['name']).toSet();
    expect(names, containsAll(['hola.txt', 'sub']));
    final sub = (data['entries'] as List).firstWhere((e) => e['name'] == 'sub');
    expect(sub['isDir'], true);
  });

  test('file download devuelve los bytes exactos', () async {
    final p = Uri.encodeComponent('${tmpRoot.path}/hola.txt');
    final resp = await req('GET', '/omarchy/file?path=$p');
    expect(resp.statusCode, 200);
    final bytes = <int>[];
    await for (final chunk in resp) {
      bytes.addAll(chunk);
    }
    expect(utf8.decode(bytes), 'contenido ohm');
  });

  test('input por REST llega al handler con acción y coordenadas', () async {
    final resp = await req('POST', '/omarchy/input',
        body: {'action': 'tap', 'x': 540, 'y': 1200});
    expect(resp.statusCode, 200);
    final data = jsonDecode(await utf8.decoder.bind(resp).join());
    expect(data['ok'], true);
    expect(inputEvents, hasLength(1));
    expect(inputEvents.first['action'], 'tap');
    expect(inputEvents.first['x'], 540);
  });

  test('ws: peer_hello, ping/pong e input con input_result', () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/omarchy/ws');
    final received = <Map<String, dynamic>>[];
    final done = Completer<void>();
    ws.listen(
      (m) => received.add(jsonDecode(m as String) as Map<String, dynamic>),
      onDone: () => done.complete(),
    );
    Future<Map<String, dynamic>> nextFrom(int index) async {
      while (received.length <= index) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      return received[index];
    }

    // peer_hello al conectar
    final hello = await nextFrom(0);
    expect(hello['type'], 'peer_hello');
    expect(hello['name'], 'TestPhone');

    // ping -> pong
    ws.add(jsonEncode({'type': 'ping'}));
    expect((await nextFrom(1))['type'], 'pong');

    // input -> handler + input_result
    ws.add(jsonEncode({'type': 'input', 'action': 'swipe', 'x1': 1, 'y1': 2, 'x2': 3, 'y2': 4}));
    final result = await nextFrom(2);
    expect(result['type'], 'input_result');
    expect(result['ok'], true);
    expect(inputEvents.last['action'], 'swipe');

    await ws.close();
    await done.future;
  });

  test('input con acción desconocida se propaga al handler (decisión del launcher)', () async {
    final resp = await req('POST', '/omarchy/input', body: {'action': 'teleport'});
    expect(resp.statusCode, 200);
    // El handler de prueba acepta todo; en producción home_screen responde
    // unknown_action. Aquí solo se verifica que el evento llega íntegro.
    expect(inputEvents.last['action'], 'teleport');
  });
}
