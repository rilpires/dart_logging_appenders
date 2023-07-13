import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import 'package:logging_appenders/src/internal/dummy_logger.dart';
import 'package:logging_appenders/src/logrecord_formatter.dart';
import 'package:logging_appenders/src/remote/base_remote_appender.dart';

final _logger = DummyLogger('logging_appenders.loki_appender');

/// Appender used to push logs to [Loki](https://github.com/grafana/loki).
class LokiApiAppender extends BaseDioLogSender {
  LokiApiAppender({
    required this.server,
    required this.username,
    required this.password,
    required this.labels,
    LogRecordFormatter? formatter,
  }) : super(formatter: formatter);

  final String server;
  final String username;
  final String password;
  Map<String, String> labels;

  String get _authHeader =>
      'Basic ${base64.encode(utf8.encode([username, password].join(':')))}';


  Dio? _clientInstance;

  Dio get _client => _clientInstance ??= Dio();

  ///
  ///
  /// It creates a stream entry for each log level
  List<LokiStream> lokiStreamsFromLogEntries(List<LogEntry> entries) {
    Map<String, List<LogEntry>> entriesByLevel = {};

    for (final entry in entries) {
      final level = entry.lineLabels['lvl'] ?? '';
      entriesByLevel.putIfAbsent(level, () => <LogEntry>[]);
      entriesByLevel[level]!.add(entry);
    }

    return entriesByLevel.entries.map((entry) {
      final labels = Map<String, String>.from(this.labels);
      if (entry.key != '') labels['level'] = entry.key;
      return LokiStream(labels, entry.value);
    }).toList(growable: false);
  }

  @override
  Future<void> sendLogEventsWithDio(List<LogEntry> entries,
      Map<String, String> userProperties, CancelToken cancelToken) {
    final jsonBody = LokiPushBody(lokiStreamsFromLogEntries(entries)).toJson();
    return _client
        .post<dynamic>(
          'https://$server/api/prom/push',
          cancelToken: cancelToken,
          data: jsonBody,
          options: Options(
            headers: <String, String>{
              HttpHeaders.authorizationHeader: _authHeader,
            },
            contentType: ContentType(
                    ContentType.json.primaryType, ContentType.json.subType)
                .value,
          ),
        )
        .then(
          (response) => Future<void>.value(null),
        )
        .catchError((Object err, StackTrace stackTrace) {
      String? message;
      if (err is DioError) {
        if (err.response != null) {
          message = 'response:${err.response!.data}';
        }
      }
      _logger.warning(
          'Error while sending logs to loki. $message', err, stackTrace);
      return Future<void>.error(err, stackTrace);
    });
  }
}

class LokiPushBody {
  LokiPushBody(this.streams);

  final List<LokiStream> streams;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'streams':
            streams.map((stream) => stream.toJson()).toList(growable: false),
      };
}

class LokiStream {
  LokiStream(this.labels, this.entries);

  final Map<String, String> labels;
  final List<LogEntry> entries;

  String toLabelString(Map<String, String> labels) =>
      '{${labels.entries.map((entry) => '${entry.key}="${entry.value}"').join(',')}}';

  static final DateFormat _dateFormat =
      DateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'");

  static String _encodeLineLabelValue(String value) {
    if (value.contains(' ')) {
      return json.encode(value);
    }
    return value;
  }

  Map<String, dynamic> toJson() =>
      <String, dynamic>{
        'labels': toLabelString(labels),
        'entries': entries
            .map((LogEntry entry) => <String, String>{
                  'ts': _dateFormat.format(entry.ts.toUtc()),
                  'line': entry.line
                })
            .toList(),
      };
}
