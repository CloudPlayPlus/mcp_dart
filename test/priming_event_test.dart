/// Priming event on POST-returned SSE, matching the Node SDK's
/// `writePrimingEvent` semantics:
///   * only when [eventStore] is configured
///   * only when the client negotiated protocol >= 2025-11-25
///   * format: `id: <eventId>\n[retry: <ms>\n]data: \n\n`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

class _RecordingEventStore implements EventStore {
  int _counter = 0;
  final List<(String, JsonRpcMessage)> stored = [];

  @override
  Future<String> storeEvent(String streamId, JsonRpcMessage message) async {
    stored.add((streamId, message));
    return 'evt-${_counter++}';
  }

  @override
  Future<String> replayEventsAfter(
    String lastEventId, {
    required Future<void> Function(String, JsonRpcMessage) send,
  }) async {
    throw UnimplementedError();
  }
}

/// Send a POST initialize + notifications/initialized + a plain request
/// that triggers the SSE response stream. Return the raw response bytes
/// of that final request.
Future<String> _postAndReadSseBody({
  required int port,
  required String protocolVersion,
}) async {
  final client = HttpClient();
  try {
    // initialize
    final initReq =
        await client.postUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
    initReq.headers
      ..set('Content-Type', 'application/json')
      ..set('Accept', 'application/json, text/event-stream');
    initReq.write(jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': protocolVersion,
        'capabilities': {},
        'clientInfo': {'name': 'probe', 'version': '0'},
      },
    }));
    final initResp = await initReq.close();
    final sid = initResp.headers.value('mcp-session-id');
    // Initialize response itself is the FIRST POST-returned SSE — return
    // its body. Don't send extra requests; keeping the test tight.
    final bytes = <int>[];
    await for (final chunk in initResp) {
      bytes.addAll(chunk);
    }
    expect(sid, isNotNull);
    return utf8.decode(bytes);
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('priming event', () {
    test('is NOT written when EventStore is absent', () async {
      final server = StreamableMcpServer(
        host: '127.0.0.1',
        port: 0,
        // no eventStore
        retryInterval: 5000,
        serverFactory: (sid) => McpServer(
          Implementation(name: 'test', version: '0.0.1'),
          options: McpServerOptions(capabilities: const ServerCapabilities()),
        ),
      );
      await server.start();
      addTearDown(server.stop);

      final body = await _postAndReadSseBody(
        port: server.boundPort!,
        protocolVersion: '2025-11-25',
      );
      expect(body, isNot(contains('retry:')));
      // The only id line should belong to the actual initialize response.
      // A priming event would have `data: \n\n` (empty data); the real
      // response has a populated data line.
      expect(body, isNot(contains('data: \ndata:')));
    });

    test('is NOT written for protocol versions older than 2025-11-25',
        () async {
      final store = _RecordingEventStore();
      final server = StreamableMcpServer(
        host: '127.0.0.1',
        port: 0,
        eventStore: store,
        retryInterval: 5000,
        serverFactory: (sid) => McpServer(
          Implementation(name: 'test', version: '0.0.1'),
          options: McpServerOptions(capabilities: const ServerCapabilities()),
        ),
      );
      await server.start();
      addTearDown(server.stop);

      final body = await _postAndReadSseBody(
        port: server.boundPort!,
        protocolVersion: '2025-06-18',
      );
      expect(body, isNot(contains('retry: 5000')));
    });

    test(
        'IS written with retry when EventStore + protocol 2025-11-25 + retryInterval',
        () async {
      final store = _RecordingEventStore();
      final server = StreamableMcpServer(
        host: '127.0.0.1',
        port: 0,
        eventStore: store,
        retryInterval: 5000,
        serverFactory: (sid) => McpServer(
          Implementation(name: 'test', version: '0.0.1'),
          options: McpServerOptions(capabilities: const ServerCapabilities()),
        ),
      );
      await server.start();
      addTearDown(server.stop);

      final body = await _postAndReadSseBody(
        port: server.boundPort!,
        protocolVersion: '2025-11-25',
      );
      // Priming event should appear BEFORE the real response.
      final primingIdx = body.indexOf('retry: 5000');
      final responseIdx = body.indexOf('"result"');
      expect(primingIdx, greaterThanOrEqualTo(0),
          reason: 'priming event missing from:\n$body');
      expect(responseIdx, greaterThan(primingIdx),
          reason: 'priming must come before the response payload');
      expect(body, contains('id: evt-'));
      // EventStore was called to mint the priming id.
      expect(store.stored, isNotEmpty);
    });

    test('IS written WITHOUT retry when retryInterval is not set', () async {
      final store = _RecordingEventStore();
      final server = StreamableMcpServer(
        host: '127.0.0.1',
        port: 0,
        eventStore: store,
        // retryInterval omitted
        serverFactory: (sid) => McpServer(
          Implementation(name: 'test', version: '0.0.1'),
          options: McpServerOptions(capabilities: const ServerCapabilities()),
        ),
      );
      await server.start();
      addTearDown(server.stop);

      final body = await _postAndReadSseBody(
        port: server.boundPort!,
        protocolVersion: '2025-11-25',
      );
      expect(body, contains('id: evt-'));
      expect(body, isNot(contains('retry:')));
    });
  });
}
