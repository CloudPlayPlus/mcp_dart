/// Integration: TCP client abrupt disconnect on the standalone SSE GET
/// must fire [StreamableMcpServer.onClientDisconnected]. Regression
/// guard for the HttpResponse.done-doesn't-fire bug.
///
/// Run: `dart test test/standalone_sse_disconnect_test.dart`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

void main() {
  test('onClientDisconnected fires when client drops TCP on standalone GET',
      () async {
    final connected = Completer<String>();
    final disconnected = Completer<String>();

    final server = StreamableMcpServer(
      host: '127.0.0.1',
      port: 0, // OS-assigned
      serverFactory: (sid) => McpServer(
        Implementation(name: 'test', version: '0.0.1'),
        options: McpServerOptions(
          capabilities: const ServerCapabilities(),
        ),
      ),
      onClientConnected: (sid) {
        if (!connected.isCompleted) connected.complete(sid);
      },
      onClientDisconnected: (sid) {
        if (!disconnected.isCompleted) disconnected.complete(sid);
      },
    );
    await server.start();
    addTearDown(server.stop);

    final port = server.boundPort!;

    // 1. Do MCP initialize via POST to get a session id.
    final client = HttpClient();
    final initReq = await client.postUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
    initReq.headers
      ..set('Content-Type', 'application/json')
      ..set('Accept', 'application/json, text/event-stream');
    initReq.write(jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-06-18',
        'capabilities': {},
        'clientInfo': {'name': 'probe', 'version': '0'},
      },
    }));
    final initResp = await initReq.close();
    final sid = initResp.headers.value('mcp-session-id');
    expect(sid, isNotNull, reason: 'server must issue session id');
    await initResp.drain();

    // Need to send notifications/initialized to finish handshake
    final notifReq =
        await client.postUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
    notifReq.headers
      ..set('Content-Type', 'application/json')
      ..set('Accept', 'application/json, text/event-stream')
      ..set('mcp-session-id', sid!);
    notifReq.write(jsonEncode({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    }));
    final notifResp = await notifReq.close();
    await notifResp.drain();

    // 2. Open GET SSE via raw socket so we can force-drop.
    final sock = await Socket.connect('127.0.0.1', port);
    sock.write(
      'GET /mcp HTTP/1.1\r\n'
      'Host: 127.0.0.1:$port\r\n'
      'Accept: text/event-stream\r\n'
      'mcp-session-id: $sid\r\n'
      '\r\n',
    );
    await sock.flush();

    // Drain response so headers process
    sock.listen((_) {}, onDone: () {}, onError: (_) {});

    // 3. Wait for onClientConnected.
    final connectedSid = await connected.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw TimeoutException('onClientConnected never fired'),
    );
    expect(connectedSid, equals(sid));

    // 4. Force-drop the TCP.
    sock.destroy();
    client.close(force: true);

    // 5. onClientDisconnected should fire quickly.
    final disconnectedSid = await disconnected.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () =>
          throw TimeoutException('onClientDisconnected never fired'),
    );
    expect(disconnectedSid, equals(sid));
  });
}
