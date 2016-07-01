// Copyright (c) 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cocoon/ioutil.dart';
import 'package:stack_trace/stack_trace.dart';

/// Whether dev server is about to exit.
bool _stopping = false;

/// Processes started by dev server.
final List<ManagedProcess> _childProcesses = <ManagedProcess>[];

final List<StreamSubscription> _streamSubscriptions = <StreamSubscription>[];

/// Proxies HTTP in front of `pub` and `goapp`.
HttpServer devServer;

const _devServerPort = 8080;
const _goappServePort = 9090;
const _pubServePort = 9091;

/// Runs `pub serve` and `goapp serve` such that the app can be debugged in
/// Dartium.
main() {
  Zone.current.fork(specification: new ZoneSpecification(handleUncaughtError: _handleCatastrophy))
    .run(() {
      Chain.capture(() async {
        await _start();
      }, onError: (error, Chain chain) {
        print(error);
        print(chain.terse);
      });
    });
}

_start() async {
  _streamSubscriptions.addAll(<StreamSubscription>[
    ProcessSignal.SIGINT.watch().listen((_) {
      print('\nReceived SIGINT. Shutting down.');
      _stop(ProcessSignal.SIGINT);
    }),
    ProcessSignal.SIGTERM.watch().listen((_) {
      print('\nReceived SIGTERM. Shutting down.');
      _stop(ProcessSignal.SIGTERM);
    }),
  ]);

  await _validateCwd();

  print('Running `goapp serve` on port $_goappServePort');
  _childProcesses.add(new ManagedProcess(
    'goapp serve',
    await startProcess('goapp', ['serve', '-port', '$_goappServePort'])
  ));

  print('Running `pub serve` on port $_pubServePort');
  _childProcesses.add(new ManagedProcess(
    'pub serve',
    await startProcess('pub', ['serve', '--port=${_pubServePort}'])
  ));

  devServer = await HttpServer.bind(InternetAddress.LOOPBACK_IP_V4, _devServerPort);
  print('Listening on http://localhost:$_devServerPort');

  try {
    await _whenLocalPortIsListening(_goappServePort);
    await _whenLocalPortIsListening(_pubServePort);
  } catch(_) {
    print('\n[ERROR] Timed out waiting for goapp and pub ports to become available\n');
    _stop();
  }

  HttpClient http = new HttpClient();
  http.autoUncompress = false;
  await for (HttpRequest request in devServer) {
    try {
      await _redirectRequest(request, http);
    } catch(e, s) {
      print('Failed redirecting ${request.uri}');
      print(e);
      print(s);
      _stop();
    }
  }
}

void _handleCatastrophy(Zone self, ZoneDelegate parent, Zone zone, error, StackTrace stackTrace) {
  print('Catastrophic error: $error\n$stackTrace');
  _stop();
}

Future<Null> _redirectRequest(HttpRequest request, HttpClient http) async {
  Uri uri = request.uri.replace(
    scheme: 'http',
    host: 'localhost',
    port: request.uri.path.contains('/api/') || request.uri.path.contains('/_ah/')
      ? _goappServePort
      : _pubServePort
  );

  HttpClientRequest proxyRequest = await http.openUrl(request.method, uri);
  request.headers.forEach((String name, List<String> values) {
    for (String value in values) {
      proxyRequest.headers.add(name, value);
    }
  });
  await proxyRequest.addStream(request);

  HttpClientResponse proxyResponse = await proxyRequest.close();
  for (String headerName in const ['content-type', 'content-encoding']) {
    request.response.headers.set(headerName, proxyResponse.headers.value(headerName));
  }
  await request.response.addStream(proxyResponse);
  await request.response.close();
}

Future<Null> _whenLocalPortIsListening(int port) async {
  Stopwatch sw = new Stopwatch()..start();
  Socket socket;
  dynamic lastError;
  dynamic lastStackTrace;

  while(sw.elapsed < const Duration(seconds: 20) && socket == null) {
    try {
      socket = await Socket.connect('localhost', port);
    } catch(error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
      await new Future.delayed(new Duration(milliseconds: 500));
    }
  }

  if (socket != null)
    await socket.close();
  else
    return new Future.error(lastError, lastStackTrace);
}

class ManagedProcess {
  ManagedProcess(this.name, this.process) {
    process.exitCode.then((int exitCode) {
      print('$name exited.');
      if (!_stopping) {
        _childProcesses.remove(process);
        _stop(ProcessSignal.SIGINT);
      }
    });
    _redirectIoStream('[$name][STDOUT]', process.stdout);
    _redirectIoStream('[$name][STDERR]', process.stderr);
  }

  void _redirectIoStream(String label, Stream<List<int>> ioStream) {
    ioStream
      .transform(const Utf8Decoder())
      .transform(const LineSplitter())
      .listen((String line) {
        print('$label: $line');
      });
  }

  final String name;
  final Process process;
}

Future<Null> _validateCwd() async {
  File pubspecYaml = file('${Directory.current.path}/pubspec.yaml');
  File appYaml = file('${Directory.current.path}/app.yaml');

  if (!(await pubspecYaml.exists())) {
    throw '${pubspecYaml.path} not found in current working directory';
  }

  if (!(await appYaml.exists())) {
    throw '${appYaml.path} not found in current working directory';
  }
}

Future<Null> _stop([ProcessSignal signal = ProcessSignal.SIGINT]) async {
  if (_stopping) {
    return;
  }
  _stopping = true;
  _streamSubscriptions.forEach((s) => s.cancel());
  await devServer.close(force: true);

  Future
    .wait(_childProcesses.map((p) => p.process.exitCode))
    .timeout(const Duration(seconds: 5))
    .whenComplete(() {
      // TODO(yjbanov): something is preventing the Dart VM from exiting and I can't
      // figure out what.
      exit(0);
    });

  while (_childProcesses.isNotEmpty) {
    ManagedProcess childProcess = _childProcesses.removeLast();
    print('Sending $signal to ${childProcess.name}');
    childProcess.process.kill(signal);
  }
}
