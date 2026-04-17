import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mcp_dart/src/server/dns_rebinding_protection.dart';
import 'package:mcp_dart/src/server/mcp_server.dart';
import 'package:mcp_dart/src/server/streamable_https.dart';
import 'package:mcp_dart/src/shared/logging.dart';
import 'package:mcp_dart/src/shared/uuid.dart';
import 'package:mcp_dart/src/types.dart';

/// A high-level server implementation that manages multiple MCP sessions over Streamable HTTP.
///
/// This server handles:
/// - HTTP server lifecycle (bind, listen, close)
/// - Session management (creation, retrieval, cleanup)
/// - Routing of MCP requests (POST) and SSE streams (GET)
/// - Authentication (optional)
///
/// Usage:
/// ```dart
/// final server = StreamableMcpServer(
///   serverFactory: (sessionId) {
///     return McpServer(
///       Implementation(name: 'my-server', version: '1.0.0'),
///     )..tool(...);
///   },
///   host: 'localhost',
///   port: 3000,
/// );
/// await server.start();
/// ```
class StreamableMcpServer {
  static final Logger _logger = Logger('StreamableMcpServer');
  static const int defaultPort = 3000;
  static const String defaultCorsMaxAgeSeconds = '86400';

  /// Factory to create a new MCP server instance for a given session.
  final McpServer Function(String sessionId) _serverFactory;

  /// Host to bind the HTTP server to.
  final String host;

  /// Port to bind the HTTP server to.
  final int port;

  /// Path to listen for MCP requests on.
  final String path;

  /// Event store for resumability support.
  final EventStore? eventStore;

  /// Optional callback to authenticate requests.
  /// Returns true if the request is allowed, false otherwise.
  final FutureOr<bool> Function(HttpRequest request)? authenticator;

  /// Enables host/origin validation to mitigate DNS rebinding attacks.
  final bool enableDnsRebindingProtection;

  /// Explicit host allowlist used when DNS rebinding protection is enabled.
  final Set<String>? allowedHosts;

  /// Explicit origin allowlist used when DNS rebinding protection is enabled.
  final Set<String>? allowedOrigins;

  /// If true, reject unsupported `MCP-Protocol-Version` headers with HTTP 400.
  final bool strictProtocolVersionHeaderValidation;

  /// If true, reject JSON-RPC batch payloads for Streamable HTTP POST requests.
  final bool rejectBatchJsonRpcPayloads;

  final Set<String> _defaultDnsRebindingAllowedHosts;

  HttpServer? _httpServer;
  final Map<String, StreamableHTTPServerTransport> _transports = {};
  // Keep track of servers to close them if needed, though closing transport usually suffices
  final Map<String, McpServer> _servers = {};

  /// Idle timeout for the underlying [HttpServer]. Dart's default is 120
  /// seconds, which kills long-lived SSE streams that go quiet. For MCP
  /// channel use the stream must survive indefinite idle periods, so the
  /// default here is `null` (disabled). Set to a non-null [Duration] if
  /// you need short-lived connections cleaned up.
  final Duration? httpIdleTimeout;

  /// Invoked when a session's standalone GET SSE stream has been accepted
  /// — i.e. a client is actively listening for server-initiated events on
  /// that session. This is the right signal for "is anyone receiving what
  /// I broadcast right now" counters. Sessions can exist without a
  /// listener (a POST initialize creates a session even if the client
  /// never opens the GET), so counting [serverFactory] invocations will
  /// over-count.
  final void Function(String sessionId)? onClientConnected;

  /// Invoked when a session's standalone GET SSE stream closes. Pairs
  /// with [onClientConnected]. Fires on TCP disconnect, DELETE request,
  /// or server shutdown.
  final void Function(String sessionId)? onClientDisconnected;

  StreamableMcpServer({
    required McpServer Function(String sessionId) serverFactory,
    this.host = 'localhost',
    this.port = defaultPort,
    this.path = '/mcp',
    this.eventStore,
    this.authenticator,
    this.enableDnsRebindingProtection = true,
    this.allowedHosts,
    this.allowedOrigins,
    this.strictProtocolVersionHeaderValidation = true,
    this.rejectBatchJsonRpcPayloads = true,
    this.httpIdleTimeout,
    this.onClientConnected,
    this.onClientDisconnected,
  })  : _serverFactory = serverFactory,
        _defaultDnsRebindingAllowedHosts = {
          normalizeDnsHost(host),
          ...defaultDnsRebindingAllowedHosts,
        };

  /// Port the underlying [HttpServer] is bound to after [start] completes.
  /// Useful when you passed `port: 0` and need to discover the
  /// OS-assigned port.
  int? get boundPort => _httpServer?.port;

  /// Starts the HTTP server.
  Future<void> start() async {
    if (_httpServer != null) {
      throw StateError('Server already started');
    }

    _httpServer = await HttpServer.bind(host, port);
    _httpServer!.idleTimeout = httpIdleTimeout;
    _logger.info(
      'MCP Streamable HTTP Server listening on http://$host:$port$path',
    );

    final httpServer = _httpServer;
    if (httpServer == null) {
      throw StateError('HTTP server not initialized');
    }
    httpServer.listen(_handleRequest);
  }

  /// Stops the HTTP server and closes all active sessions.
  Future<void> stop() async {
    await _httpServer?.close(force: true);
    _httpServer = null;

    // Close all transports
    for (final transport in _transports.values) {
      await transport.close();
    }
    _transports.clear();
    _servers.clear();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _setCorsHeaders(request.response);

    if (enableDnsRebindingProtection &&
        !isRequestAllowedByDnsRebindingProtection(
          request,
          allowedHosts: allowedHosts,
          allowedOrigins: allowedOrigins,
          defaultAllowedHosts: _defaultDnsRebindingAllowedHosts,
        )) {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..write('Forbidden: blocked by DNS rebinding protection');
      await request.response.close();
      return;
    }

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    if (request.uri.path != path) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not Found')
        ..close();
      return;
    }

    if (authenticator != null) {
      bool allowed = false;
      try {
        allowed = await authenticator!(request);
      } catch (e) {
        _logger.error('Authentication error: $e');
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Authentication Error')
          ..close();
        return;
      }

      if (!allowed) {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..write('Forbidden')
          ..close();
        return;
      }
    }

    try {
      if (request.method == 'POST') {
        await _handlePostRequest(request);
      } else if (request.method == 'GET') {
        await _handleGetRequest(request);
      } else if (request.method == 'DELETE') {
        await _handleDeleteRequest(request);
      } else {
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..headers.set(HttpHeaders.allowHeader, 'GET, POST, DELETE, OPTIONS')
          ..write('Method Not Allowed')
          ..close();
      }
    } catch (e, stack) {
      _logger.error('Error handling request: $e\n$stack');
      if (!request.response.headers.contentType
          .toString()
          .startsWith('text/event-stream')) {
        try {
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..write('Internal Server Error')
            ..close();
        } catch (_) {
          // Response might be already closed
        }
      }
    }
  }

  Future<void> _handlePostRequest(HttpRequest request) async {
    // We need to read the body to determine if it's an initialization request
    // or a request for an existing session.
    // However, StreamableHTTPServerTransport.handleRequest expects to read the body itself
    // OR be passed the parsed body.
    // To support the routing logic (new vs existing session), we must read it here.

    final bodyBytes = await _collectBytes(request);
    final bodyString = utf8.decode(bodyBytes);
    dynamic body;
    try {
      body = jsonDecode(bodyString);
    } catch (e) {
      await _respondWithJsonRpcError(
        request.response,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.parseError,
        message: 'Parse error',
      );
      return;
    }

    if (rejectBatchJsonRpcPayloads && body is List) {
      await _respondWithJsonRpcError(
        request.response,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.invalidRequest,
        message: 'Invalid Request: Batch JSON-RPC payloads are not supported',
      );
      return;
    }

    if (body is! Map && body is! List) {
      await _respondWithJsonRpcError(
        request.response,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.invalidRequest,
        message:
            'Invalid Request: POST body must contain a JSON-RPC message object',
      );
      return;
    }

    final sessionId = request.headers.value('mcp-session-id');
    StreamableHTTPServerTransport? transport;

    if (sessionId != null && _transports.containsKey(sessionId)) {
      transport = _transports[sessionId]!;
    } else if (sessionId == null && _isInitializeRequest(body)) {
      // New initialization request
      transport = _createTransport();

      // We need to pass the body we already read to the transport
      await transport.handleRequest(request, body);
      return;
    } else {
      await _respondWithJsonRpcError(
        request.response,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.connectionClosed,
        message:
            'Bad Request: No valid session ID provided or not an initialization request',
      );
      return;
    }

    // Handle the request with existing transport
    await transport.handleRequest(request, body);
  }

  Future<void> _handleGetRequest(HttpRequest request) async {
    final sessionId = request.headers.value('mcp-session-id');
    if (sessionId == null || !_transports.containsKey(sessionId)) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid or missing session ID')
        ..close();
      return;
    }

    final transport = _transports[sessionId]!;
    await transport.handleRequest(request);
  }

  Future<void> _handleDeleteRequest(HttpRequest request) async {
    final sessionId = request.headers.value('mcp-session-id');
    if (sessionId == null || !_transports.containsKey(sessionId)) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid or missing session ID')
        ..close();
      return;
    }

    final transport = _transports[sessionId]!;
    await transport.handleRequest(request);
  }

  StreamableHTTPServerTransport _createTransport() {
    late StreamableHTTPServerTransport transport;

    transport = StreamableHTTPServerTransport(
      options: StreamableHTTPServerTransportOptions(
        sessionIdGenerator: () => generateUUID(),
        eventStore: eventStore,
        enableDnsRebindingProtection: enableDnsRebindingProtection,
        allowedHosts: allowedHosts ?? {host},
        allowedOrigins: allowedOrigins,
        strictProtocolVersionHeaderValidation:
            strictProtocolVersionHeaderValidation,
        rejectBatchJsonRpcPayloads: rejectBatchJsonRpcPayloads,
        onsessioninitialized: (sid) {
          _logger.info('Session initialized: $sid');
          _transports[sid] = transport;

          // Create and connect the MCP server
          final server = _serverFactory(sid);
          _servers[sid] = server;

          // Connect server to transport
          // Note: connect() is async, but onsessioninitialized is sync.
          // This usually works because the transport handles the immediate request
          // and the server will be hooked up for subsequent messages or the current one
          // if handleRequest logic flows correctly.
          // However, for initialization, the Server needs to be connected to handle the
          // 'initialize' message that is currently being processed.
          //
          // StreamableHTTPServerTransport calls onsessioninitialized BEFORE processing messages.
          // So we should connect here.
          server.connect(transport).catchError((e) {
            _logger.error('Error connecting server to transport: $e');
            _transports.remove(sid);
            _servers.remove(sid);
          });
        },
      ),
    );

    transport.onclose = () {
      final sid = transport.sessionId;
      if (sid != null) {
        _transports.remove(sid);
        _servers.remove(sid); // This will be GC'd
        _logger.info('Session closed: $sid');
      }
    };

    if (onClientConnected != null || onClientDisconnected != null) {
      transport.onstandalonesseopen = () {
        final sid = transport.sessionId;
        if (sid != null) onClientConnected?.call(sid);
      };
      transport.onstandalonesseclose = () {
        final sid = transport.sessionId;
        if (sid != null) onClientDisconnected?.call(sid);
      };
    }

    return transport;
  }

  bool _isInitializeRequest(dynamic body) {
    if (body is Map<String, dynamic> &&
        body.containsKey('method') &&
        body['method'] == 'initialize') {
      return true;
    }
    // Batch request check
    if (body is List && body.isNotEmpty) {
      for (final item in body) {
        if (item is Map<String, dynamic> &&
            item.containsKey('method') &&
            item['method'] == 'initialize') {
          return true;
        }
      }
    }
    return false;
  }

  Future<Uint8List> _collectBytes(HttpRequest request) async {
    final completer = Completer<Uint8List>();
    final sink = BytesBuilder();

    request.listen(
      sink.add,
      onDone: () => completer.complete(sink.takeBytes()),
      onError: completer.completeError,
      cancelOnError: true,
    );

    return completer.future;
  }

  Future<void> _respondWithJsonRpcError(
    HttpResponse response, {
    required int httpStatus,
    required ErrorCode errorCode,
    required String message,
    Object? data,
  }) async {
    response
      ..statusCode = httpStatus
      ..write(
        jsonEncode(
          JsonRpcError(
            id: null,
            error: JsonRpcErrorData(
              code: errorCode.value,
              message: message,
              data: data,
            ),
          ).toJson(),
        ),
      );
    await response.close();
  }

  void _setCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers
        .set('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
    response.headers.set(
      'Access-Control-Allow-Headers',
      'Origin, X-Requested-With, Content-Type, Accept, mcp-session-id, Last-Event-ID, Authorization, MCP-Protocol-Version',
    );
    response.headers.set('Access-Control-Allow-Credentials', 'true');
    response.headers.set('Access-Control-Max-Age', defaultCorsMaxAgeSeconds);
    response.headers.set('Access-Control-Expose-Headers', 'mcp-session-id');
  }
}
