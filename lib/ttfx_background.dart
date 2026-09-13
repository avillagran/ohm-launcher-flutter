import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:xterm/xterm.dart';

@visibleForTesting
List<String> buildTtfxFrameArgs({
  required String binaryPath,
  required String inputPath,
  required int fps,
  required int columns,
  required int rows,
  required String effect,
}) {
  return [
    binaryPath,
    '--input-file',
    inputPath,
    '--frame-rate',
    '$fps',
    '--canvas-width',
    '$columns',
    '--canvas-height',
    '$rows',
    '--ignore-terminal-dimensions',
    '--final-text-bands',
    '--anchor-canvas',
    'c',
    '--anchor-text',
    'c',
    '--parity-dump',
    '--pace-dump',
    effect,
  ];
}

@visibleForTesting
Stream<String> decodeTtfxFrames(Stream<List<int>> source) async* {
  var pending = <int>[];
  var offset = 0;
  int? expected;
  await for (final chunk in source) {
    pending.addAll(chunk);
    while (true) {
      if (expected == null) {
        final newline = pending.indexOf(10, offset);
        if (newline < 0) break;
        expected = int.parse(ascii.decode(pending.sublist(offset, newline)));
        offset = newline + 1;
      }
      if (pending.length - offset < expected + 1) break;
      final frame = utf8.decode(
        pending.sublist(offset, offset + expected),
        allowMalformed: true,
      );
      offset += expected;
      if (pending[offset] != 10) {
        throw const FormatException('TTFX frame separator missing');
      }
      offset++;
      expected = null;
      yield frame.endsWith('\n') ? frame.substring(0, frame.length - 1) : frame;
    }
    if (offset > 0) {
      pending = pending.sublist(offset);
      offset = 0;
    }
  }
  if (expected != null || pending.isNotEmpty) {
    throw const FormatException('Truncated TTFX frame stream');
  }
}

@visibleForTesting
String ttfxRasterSequence(String frame) =>
    '\x1b[?7l\x1b[H${frame.replaceAll('\n', '\r\n')}';

@visibleForTesting
int ttfxVisibleGlyphCount(String frame) {
  var count = 0;
  var escape = false;
  var csi = false;
  for (final rune in frame.runes) {
    if (csi) {
      if (rune >= 0x40 && rune <= 0x7e) {
        csi = false;
        escape = false;
      }
      continue;
    }
    if (escape) {
      if (rune == 0x5b) {
        csi = true;
      } else {
        escape = false;
      }
      continue;
    }
    if (rune == 0x1b) {
      escape = true;
    } else if (rune > 32) {
      count++;
    }
  }
  return count;
}

@visibleForTesting
int ttfxCanvasColumns(int resolution, String text, int textSize) {
  final configured = (160 / math.sqrt(resolution.clamp(1, 8))).round().clamp(
    40,
    120,
  );
  if (text.trim().toLowerCase() != 'omarchy') return configured;
  final detailBoost = switch (textSize.clamp(1, 7)) {
    6 => 1.15,
    7 => 1.30,
    _ => 1.0,
  };
  return (configured * detailBoost).round().clamp(40, 120);
}

// Official bitmap sampled on logo.svg's 15 px grid (81×19). Do not replace it
// with a font: its asymmetric cells form the wordmark.
const _omarchyBitmap = <String>[
  '.................###.............................................................',
  '..#####......###########......#######....#######....#######....#...#......#...#..',
  '.#######....#############....########...########...########...##...##....##...##.',
  '###...###..###...###...###..###...###..###...###..###...###..###...###..###...###',
  '###...###..###...###...###..###...###..###...###..###...###..###...###..###...###',
  '###...###..###...###...###..###...###..###...###..###...##...###...###..###...###',
  '###...###..###...###...###..###...###..###...###..###...#....###...###..###...###',
  '###...###..###...###...###..###...###..###...###..###........###...###..###...###',
  '###...###..###...###...###.##########.#########...###.......###########.#########',
  '###...###..###...###...###.##########.########....###......###########..#########',
  '###...###..###...###...###..###...###..###........###........###...###........###',
  '###...###..###...###...###..###...###.##########..###...#....###...###...##...###',
  '###...###..###...###...###..###...###.##########..###...##...###...###..###...###',
  '###...###..###...###...###..###...###..###...###..###...###..###...###..###...###',
  '###...###..###...###...###..###...###..###...###..###...###..###...###..###...###',
  '.#######....##...###...##...###...##...###...###..########...###...##....#######.',
  '..#####......#...###...#....###...#....###...###..#######....###...#......#####..',
  '.......................................###...##..................................',
  '.......................................###...#...................................',
];

@visibleForTesting
String officialOmarchyCellArt(int columns, int rows, int textSize) {
  final widthFactor = const [
    .44,
    .57,
    .70,
    .83,
    .96,
    .98,
    1.0,
  ][textSize.clamp(1, 7) - 1];
  final targetColumns = (columns * widthFactor).round().clamp(12, columns);
  // Terminal cells are taller than they are wide. Compensate for their actual
  // 0.62 width and 1.05 line-height so the 81:19 source keeps its logo aspect.
  final targetRows = (targetColumns * (.62 / 1.05) * (19 / 81)).round().clamp(
    3,
    rows,
  );
  const sourceSeparators = [9.5, 26.0, 37.0, 48.5, 71.0];
  final separatorColumns = sourceSeparators
      .map((source) => (source * targetColumns / 81).round())
      .toSet();
  final out = StringBuffer();
  for (var row = 0; row < targetRows; row++) {
    final sourceTop = row * 19 ~/ targetRows;
    final sourceBottom = math.max(sourceTop + 1, (row + 1) * 19 ~/ targetRows);
    for (var column = 0; column < targetColumns; column++) {
      final sourceLeft = column * 81 ~/ targetColumns;
      final sourceRight = math.max(
        sourceLeft + 1,
        (column + 1) * 81 ~/ targetColumns,
      );
      var filled = 0;
      var samples = 0;
      for (var y = sourceTop; y < sourceBottom; y++) {
        for (var x = sourceLeft; x < sourceRight; x++) {
          if (_omarchyBitmap[y][x] == '#') filled++;
          samples++;
        }
      }
      out.write(
        separatorColumns.contains(column) || filled / samples < .28 ? ' ' : '█',
      );
    }
    if (row + 1 < targetRows) out.write('\n');
  }
  return out.toString();
}

/// Native Flutter port of the eight hand-written effects in
/// `omarchy-audio-background`.
///
/// The desktop implementation paints terminal cells; this renderer keeps that
/// character-grid look while drawing directly into the launcher's canvas. The
/// Android output-mix FFT drives volume, beat and 16 frequency bands.
class TtfxBackground extends StatefulWidget {
  const TtfxBackground({
    super.key,
    required this.effect,
    this.enabled = true,
    this.audioReactive = true,
    this.text = 'OHM',
    this.textSize = 3,
    this.textX = .5,
    this.textY = .5,
    this.intensity = 5,
    this.speed = 1,
    this.resolution = 2,
    this.reactivity = 2,
    this.accent = const Color(0xFF66E0FF),
  });

  static const nativeEffects = <String>[
    'matrix',
    'rain',
    'wave',
    'bars',
    'donut',
    'fire',
    'starfield',
    'life',
  ];

  /// Real effects provided by the cross-compiled Rust ttfx engine.
  static const ttfxEffects = <String>[
    'beams',
    'binarypath',
    'blackhole',
    'bouncyballs',
    'bubbles',
    'burn',
    'colorshift',
    'crumble',
    'decrypt',
    'errorcorrect',
    'expand',
    'fireworks',
    'highlight',
    'laseretch',
    'ttfx-matrix',
    'middleout',
    'orbittingvolley',
    'overflow',
    'pour',
    'print',
    'ttfx-rain',
    'randomsequence',
    'rings',
    'scattered',
    'slice',
    'slide',
    'smoke',
    'spotlights',
    'spray',
    'swarm',
    'sweep',
    'synthgrid',
    'thunderstorm',
    'unstable',
    'vhstape',
    'waves',
    'wipe',
  ];

  static const effects = <String>[...nativeEffects, ...ttfxEffects];

  static bool isTtfxEffect(String effect) => ttfxEffects.contains(effect);

  static String effectLabel(String effect) {
    final name = effect.startsWith('ttfx-') ? effect.substring(5) : effect;
    return '$name (${isTtfxEffect(effect) ? 'TTFX' : 'nativo'})';
  }

  final String effect;
  final bool enabled;
  final bool audioReactive;
  final String text;
  final int textSize;
  final double textX;
  final double textY;
  final int intensity;
  final double speed;
  final int resolution;
  final int reactivity;
  final Color accent;

  @override
  State<TtfxBackground> createState() => _TtfxBackgroundState();
}

class _TtfxBackgroundState extends State<TtfxBackground>
    with WidgetsBindingObserver {
  static const _audioChannel = EventChannel('com.ohm/audio_spectrum');
  final ValueNotifier<double> _clock = ValueNotifier(0);
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _frameTimer;
  final ValueNotifier<TtfxSpectrum> _spectrum = ValueNotifier(
    const TtfxSpectrum.silent(),
  );
  StreamSubscription<dynamic>? _audioSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startClock();
    _syncAudio();
  }

  @override
  void didUpdateWidget(covariant TtfxBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioReactive != widget.audioReactive ||
        oldWidget.enabled != widget.enabled) {
      _syncAudio();
    }
    if (widget.enabled) {
      _startClock();
    } else {
      _stopClock();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.enabled) {
      _startClock();
      _syncAudio();
    } else if (state != AppLifecycleState.resumed) {
      _stopClock();
      _audioSub?.cancel();
      _audioSub = null;
    }
  }

  Future<void> _syncAudio() async {
    await _audioSub?.cancel();
    _audioSub = null;
    if (!widget.enabled || !widget.audioReactive) {
      _spectrum.value = const TtfxSpectrum.silent();
      return;
    }
    if (!await Permission.microphone.isGranted) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        _spectrum.value = const TtfxSpectrum.silent();
        return;
      }
    }
    _audioSub = _audioChannel.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final rawBands = event['bands'];
      final bands = rawBands is List
          ? rawBands.map((e) => (e as num?)?.toDouble() ?? 0).toList()
          : const <double>[];
      _spectrum.value = TtfxSpectrum(
        volume: ((event['volume'] as num?)?.toDouble() ?? 0).clamp(0, 1),
        beat: event['beat'] == true,
        bands: List<double>.generate(
          16,
          (i) => i < bands.length ? bands[i].clamp(0, 1) : 0,
        ),
      );
    }, onError: (_) => _spectrum.value = const TtfxSpectrum.silent());
  }

  void _startClock() {
    if (_frameTimer != null) return;
    _stopwatch.start();
    // 30 FPS matches the terminal renderer's visual cadence while avoiding a
    // permanent 60 FPS load behind every launcher widget.
    _frameTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _clock.value =
          _stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond;
    });
  }

  void _stopClock() {
    _frameTimer?.cancel();
    _frameTimer = null;
    _stopwatch.stop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _audioSub?.cancel();
    _stopClock();
    _clock.dispose();
    _spectrum.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    if (TtfxBackground.isTtfxEffect(widget.effect)) {
      return LayoutBuilder(
        builder: (context, constraints) => _TtfxTerminalBackground(
          effect: widget.effect,
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          speed: widget.speed,
          resolution: widget.resolution,
          text: widget.text,
          textSize: widget.textSize,
          textX: widget.textX,
          textY: widget.textY,
          spectrum: _spectrum,
          reactivity: widget.reactivity,
        ),
      );
    }
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: TtfxBackgroundPainter(
            effect: TtfxBackground.effects.contains(widget.effect)
                ? widget.effect
                : 'matrix',
            clock: _clock,
            spectrum: _spectrum,
            intensity: widget.intensity.clamp(0, 10),
            speed: widget.speed.clamp(0.2, 20),
            resolution: widget.resolution.clamp(1, 8),
            reactivity: widget.reactivity.clamp(0, 5),
            accent: widget.accent,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// Runs the real Rust ttfx engine in a PTY and paints its ANSI frames with the
/// same xterm renderer already used by the Quake terminal.
class _TtfxTerminalBackground extends StatefulWidget {
  const _TtfxTerminalBackground({
    required this.effect,
    required this.width,
    required this.height,
    required this.speed,
    required this.resolution,
    required this.text,
    required this.textSize,
    required this.textX,
    required this.textY,
    required this.spectrum,
    required this.reactivity,
  });

  final String effect;
  final double width;
  final double height;
  final double speed;
  final int resolution;
  final String text;
  final int textSize;
  final double textX;
  final double textY;
  final ValueListenable<TtfxSpectrum> spectrum;
  final int reactivity;

  @override
  State<_TtfxTerminalBackground> createState() =>
      _TtfxTerminalBackgroundState();
}

class _TtfxTerminalBackgroundState extends State<_TtfxTerminalBackground>
    with WidgetsBindingObserver {
  static const _platform = MethodChannel('com.ohm/ohm');
  late Terminal _terminal;
  Process? _process;
  StreamSubscription<String>? _stderr;
  String? _error;
  int _generation = 0;
  List<double> _currentAudioMatrix = const <double>[
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];

  int get _columns =>
      ttfxCanvasColumns(widget.resolution, widget.text, widget.textSize);

  double get _fontSize => widget.width / (_columns * .62);

  int get _rows => (widget.height / (_fontSize * 1.05)).floor().clamp(12, 160);

  String get _engineEffect {
    if (widget.effect == 'ttfx-matrix') return 'matrix';
    if (widget.effect == 'ttfx-rain') return 'rain';
    return widget.effect;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _newTerminal();
    unawaited(_start(_generation));
  }

  void _newTerminal() {
    _terminal = Terminal(maxLines: _rows, reflowEnabled: false)
      ..resize(_columns, _rows);
  }

  @override
  void didUpdateWidget(covariant _TtfxTerminalBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.effect != widget.effect ||
        oldWidget.text != widget.text ||
        oldWidget.textSize != widget.textSize ||
        oldWidget.resolution != widget.resolution ||
        oldWidget.speed != widget.speed ||
        oldWidget.width.round() != widget.width.round() ||
        oldWidget.height.round() != widget.height.round()) {
      unawaited(_restart());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_process == null) unawaited(_start(_generation));
    } else {
      _stop();
    }
  }

  Future<void> _restart() async {
    _stop();
    final generation = _generation;
    _newTerminal();
    if (mounted) setState(() => _error = null);
    await _start(generation);
  }

  /// Converts arbitrary Unicode text to centered terminal-cell artwork.
  Future<String> _convertTextToCells(String input) async {
    if (input.trim().toLowerCase() == 'omarchy') {
      return officialOmarchyCellArt(_columns, _rows, widget.textSize);
    }
    // Wrap before rasterizing so a long input is enlarged rather than crushed
    // into four illegible rows. Explicit newlines are preserved.
    final maxChars = ((_columns - 4) / (4 + widget.textSize.clamp(1, 7) * 1.5))
        .floor()
        .clamp(3, 40);
    final wrappedLines = <String>[];
    for (final sourceLine in input.split('\n')) {
      var remaining = sourceLine;
      while (remaining.length > maxChars) {
        var cut = remaining.lastIndexOf(' ', maxChars);
        if (cut < maxChars ~/ 2) cut = maxChars;
        wrappedLines.add(remaining.substring(0, cut).trimRight());
        remaining = remaining.substring(cut).trimLeft();
      }
      wrappedLines.add(remaining);
    }
    final wrapped = wrappedLines.join('\n');
    final painter = TextPainter(
      text: TextSpan(
        text: wrapped,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 96,
          height: 1.05,
          fontWeight: FontWeight.w800,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 2048);
    final width = painter.width.ceil().clamp(1, 2048);
    final height = painter.height.ceil().clamp(1, 2048);
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), Offset.zero);
    final image = await recorder.endRecording().toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    if (data == null) return input;
    final pixels = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final lineCount = wrappedLines.length;
    var targetRows = ((4 + widget.textSize.clamp(1, 7) * 3) * lineCount).clamp(
      4,
      _rows - 4,
    );
    var targetCols = (targetRows * width / height / .62).round().clamp(
      4,
      _columns - 4,
    );
    if (targetCols >= _columns - 4) {
      targetRows = ((_columns - 4) * height * .62 / width).round().clamp(
        4,
        _rows - 4,
      );
      targetCols = (_columns - 4).clamp(4, _columns);
    }
    final out = StringBuffer();
    for (var row = 0; row < targetRows; row++) {
      final y0 = row * height ~/ targetRows;
      final y1 = math.max(y0 + 1, (row + 1) * height ~/ targetRows);
      for (var col = 0; col < targetCols; col++) {
        final x0 = col * width ~/ targetCols;
        final x1 = math.max(x0 + 1, (col + 1) * width ~/ targetCols);
        var alpha = 0;
        var samples = 0;
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            alpha += pixels[(y * width + x) * 4 + 3];
            samples++;
          }
        }
        final coverage = samples == 0 ? 0 : alpha / (samples * 255);
        out.write(
          coverage > .58
              ? '█'
              : coverage > .26
              ? '▓'
              : coverage > .07
              ? '░'
              : ' ',
        );
      }
      if (row + 1 < targetRows) out.write('\n');
    }
    return _trimCellArt(out.toString());
  }

  String _trimCellArt(String art) {
    var lines = art.split('\n');
    while (lines.isNotEmpty && lines.first.trim().isEmpty) {
      lines = lines.sublist(1);
    }
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines = lines.sublist(0, lines.length - 1);
    }
    if (lines.isEmpty) return art;
    var leftTrim = lines
        .where((line) => line.trim().isNotEmpty)
        .map((line) => line.length - line.trimLeft().length)
        .reduce(math.min);
    lines = lines
        .map((line) => line.substring(math.min(leftTrim, line.length)))
        .toList();
    return lines.join('\n');
  }

  Future<void> _start(int generation) async {
    if (_process != null || !Platform.isAndroid) return;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/ttfx');
      await dir.create(recursive: true);
      final abi = await _platform.invokeMethod<String>('getNativeAbi') ?? '';
      final asset = abi.contains('x86_64')
          ? 'assets/bin/ttfx-x86_64'
          : 'assets/bin/ttfx-aarch64';
      final binary = File('${dir.path}/ttfx');
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (!await binary.exists() || await binary.length() != bytes.length) {
        await binary.writeAsBytes(bytes, flush: true);
      }
      await Process.run('/system/bin/chmod', ['0700', binary.path]);
      final input = File('${dir.path}/ohm.txt');
      final requested = widget.text.trim().isEmpty ? 'OHM' : widget.text.trim();
      final safeText = requested.length > 160
          ? requested.substring(0, 160)
          : requested;
      final cellText = await _convertTextToCells(safeText);
      await input.writeAsString('$cellText\n', flush: true);
      if (!mounted || generation != _generation || _process != null) return;
      // Flutter's xterm renderer repaints ANSI cell updates on the UI thread.
      // Above 30 FPS the Xiaomi drops whole Flutter frames, especially while
      // audio color filtering also invalidates this layer.
      final fps = (15 * widget.speed).round().clamp(5, 30);
      final args = buildTtfxFrameArgs(
        binaryPath: binary.path,
        inputPath: input.path,
        fps: fps,
        columns: _columns,
        rows: _rows,
        effect: _engineEffect,
      );
      final targetGlyphs = cellText.runes.where((rune) => rune > 32).length;
      String? lastPresentedFrame;
      while (mounted && generation == _generation) {
        final process = await Process.start(
          '/system/bin/linker64',
          args,
          workingDirectory: dir.path,
          environment: const {
            'LANG': 'en_US.UTF-8',
            'HOME': '/data/local/tmp',
            'PATH': '/system/bin:/system/xbin',
          },
        );
        if (!mounted || generation != _generation) {
          process.kill(ProcessSignal.sigkill);
          return;
        }
        _process = process;
        _stderr = process.stderr
            .transform(utf8.decoder)
            .listen((_) {}, onError: (_) {});
        var waitingForFirstVisibleFrame = true;
        await for (final frame in decodeTtfxFrames(process.stdout)) {
          if (!mounted || generation != _generation) {
            process.kill(ProcessSignal.sigkill);
            return;
          }
          // Retain the previous raster until this pass contains enough real
          // content to replace it, rather than flashing a nearly empty frame.
          if (waitingForFirstVisibleFrame &&
              ttfxVisibleGlyphCount(frame) < math.max(1, targetGlyphs ~/ 20)) {
            continue;
          }
          waitingForFirstVisibleFrame = false;
          // Several finite effects append 20–30 byte-identical hold frames.
          // Sleeping for each one freezes the background for almost a second;
          // collapse only exact duplicates and preserve every real transition.
          if (frame == lastPresentedFrame) continue;
          // Framed output is a rectangular raster, not terminal prose. Disable
          // DEC autowrap and add CR to each LF so an exact-width row advances
          // once and starts at column zero; otherwise xterm scrolls the centered
          // image toward the top on every frame.
          final nextMatrix = _audioColorMatrix(widget.spectrum.value);
          if (_matrixDistance(_currentAudioMatrix, nextMatrix) >= .015) {
            setState(() => _currentAudioMatrix = nextMatrix);
          }
          _terminal.write(ttfxRasterSequence(frame));
          lastPresentedFrame = frame;
          // Process stdout may coalesce several paced Rust frames into one
          // platform chunk. Yield after each raster so xterm never parses that
          // burst in a single UI-thread turn.
          await SchedulerBinding.instance.endOfFrame;
        }
        final exitCode = await process.exitCode;
        await _stderr?.cancel();
        _stderr = null;
        if (identical(_process, process)) _process = null;
        if (!mounted || generation != _generation) return;
        if (exitCode != 0) {
          throw ProcessException(
            '/system/bin/linker64',
            args,
            'TTFX frame process exited unexpectedly',
            exitCode,
          );
        }
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$e');
      }
    }
  }

  void _stop() {
    _generation++;
    _stderr?.cancel();
    _stderr = null;
    final process = _process;
    _process = null;
    process?.kill(ProcessSignal.sigkill);
  }

  List<double> _audioColorMatrix(TtfxSpectrum spectrum) {
    if (widget.reactivity <= 0) {
      return const <double>[
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ];
    }
    final strength = widget.reactivity / 2;
    final volume = spectrum.volume.clamp(0, 1);
    final bass = (spectrum.bands[0] + spectrum.bands[1] * .5).clamp(0, 1);
    final brightness = (1 + volume * .35 * strength).clamp(1, 1.7);
    // Fire keeps its semantic hue, matching omarchy-audio-background; every
    // other real TTFX effect rotates with bass and flashes slightly on beats.
    final degrees = _engineEffect == 'burn'
        ? 0.0
        : (bass * 45 + volume * 18 + (spectrum.beat ? 10 : 0)) * strength;
    final angle = degrees * math.pi / 180;
    final c = math.cos(angle), s = math.sin(angle), t = 1 - c;
    const w = .577350269;
    return <double>[
      (c + t / 3) * brightness,
      (t / 3 - w * s) * brightness,
      (t / 3 + w * s) * brightness,
      0,
      0,
      (t / 3 + w * s) * brightness,
      (c + t / 3) * brightness,
      (t / 3 - w * s) * brightness,
      0,
      0,
      (t / 3 - w * s) * brightness,
      (t / 3 + w * s) * brightness,
      (c + t / 3) * brightness,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  double _matrixDistance(List<double> first, List<double> second) {
    var distance = 0.0;
    for (var i = 0; i < first.length; i++) {
      distance = math.max(distance, (first[i] - second[i]).abs());
    }
    return distance;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(
          'TTFX: $_error',
          style: const TextStyle(color: Color(0xFFFF6B7A), fontSize: 11),
        ),
      );
    }
    return IgnorePointer(
      child: ClipRect(
        child: ColorFiltered(
          colorFilter: ColorFilter.matrix(_currentAudioMatrix),
          child: AnimatedSlide(
            offset: Offset(
              widget.textX.clamp(0, 1) - .5,
              widget.textY.clamp(0, 1) - .5,
            ),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: TerminalView(
              _terminal,
              readOnly: true,
              hardwareKeyboardOnly: true,
              autoResize: false,
              backgroundOpacity: 0,
              padding: EdgeInsets.zero,
              textStyle: TerminalStyle(
                fontSize: _fontSize,
                height: 1.05,
                fontFamily: 'monospace',
              ),
              theme: TerminalThemes.whiteOnBlack,
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact on-desktop controller for cycling effects and nudging text without
/// reopening the full desktop settings sheet.
class TtfxMiniControls extends StatefulWidget {
  const TtfxMiniControls({
    super.key,
    required this.effect,
    required this.x,
    required this.y,
    required this.onPreviousEffect,
    required this.onNextEffect,
    required this.onXChanged,
    required this.onYChanged,
  });

  final String effect;
  final double x;
  final double y;
  final VoidCallback onPreviousEffect;
  final VoidCallback onNextEffect;
  final ValueChanged<double> onXChanged;
  final ValueChanged<double> onYChanged;

  @override
  State<TtfxMiniControls> createState() => _TtfxMiniControlsState();
}

class _TtfxMiniControlsState extends State<TtfxMiniControls> {
  bool _expanded = false;
  late double _x = widget.x;
  late double _y = widget.y;

  @override
  void didUpdateWidget(covariant TtfxMiniControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.x != widget.x) _x = widget.x;
    if (oldWidget.y != widget.y) _y = widget.y;
  }

  Widget _button(IconData icon, String tooltip, VoidCallback onPressed) {
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 18, color: const Color(0xFF66E0FF)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xDD10161C),
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 160),
        child: !_expanded
            ? _button(
                Icons.auto_awesome,
                'Controles TTFX',
                () => setState(() => _expanded = true),
              )
            : Padding(
                padding: const EdgeInsets.all(5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _button(
                          Icons.skip_previous,
                          'Efecto anterior',
                          widget.onPreviousEffect,
                        ),
                        SizedBox(
                          width: 92,
                          child: Text(
                            TtfxBackground.effectLabel(widget.effect),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFFE8F1F8),
                              fontSize: 10,
                            ),
                          ),
                        ),
                        _button(
                          Icons.skip_next,
                          'Efecto siguiente',
                          widget.onNextEffect,
                        ),
                        _button(
                          Icons.close,
                          'Cerrar controles',
                          () => setState(() => _expanded = false),
                        ),
                      ],
                    ),
                    SizedBox(
                      width: 224,
                      child: Row(
                        children: [
                          Text(
                            'X ${(_x * 100).round()}',
                            style: const TextStyle(
                              color: Color(0xFF9FB3C8),
                              fontSize: 9,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              min: 0,
                              max: 1,
                              divisions: 20,
                              value: _x.clamp(0, 1),
                              onChanged: (value) => setState(() => _x = value),
                              onChangeEnd: widget.onXChanged,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 224,
                      child: Row(
                        children: [
                          Text(
                            'Y ${(_y * 100).round()}',
                            style: const TextStyle(
                              color: Color(0xFF9FB3C8),
                              fontSize: 9,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              min: 0,
                              max: 1,
                              divisions: 20,
                              value: _y.clamp(0, 1),
                              onChanged: (value) => setState(() => _y = value),
                              onChangeEnd: widget.onYChanged,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

@immutable
class TtfxSpectrum {
  const TtfxSpectrum({
    required this.volume,
    required this.beat,
    required this.bands,
  });
  const TtfxSpectrum.silent()
    : volume = 0,
      beat = false,
      bands = const <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

  final double volume;
  final bool beat;
  final List<double> bands;
}

class TtfxBackgroundPainter extends CustomPainter {
  TtfxBackgroundPainter({
    required this.effect,
    required this.clock,
    required this.spectrum,
    required this.intensity,
    required this.speed,
    required this.resolution,
    required this.reactivity,
    required this.accent,
  }) : super(repaint: Listenable.merge([clock, spectrum]));

  final String effect;
  final ValueListenable<double> clock;
  final ValueListenable<TtfxSpectrum> spectrum;
  final int intensity;
  final double speed;
  final int resolution;
  final int reactivity;
  final Color accent;

  double get _time => clock.value * speed;
  double get _volume => spectrum.value.volume * (reactivity / 2).clamp(0, 2.5);
  List<double> get _bands => spectrum.value.bands;

  Color _tone(double light, [double hueOffset = 0]) {
    final hsv = HSVColor.fromColor(accent);
    final bass = _bands.isEmpty ? 0 : (_bands[0] + _bands[1] * .5).clamp(0, 1);
    final shift =
        (bass * 45 + _volume * 18 + (spectrum.value.beat ? 10 : 0)) *
        (reactivity / 2);
    return hsv
        .withHue((hsv.hue + hueOffset + shift) % 360)
        .withSaturation((hsv.saturation * .9).clamp(.35, 1))
        .withValue((light * (1 + _volume * .35)).clamp(0, 1))
        .toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    switch (effect) {
      case 'rain':
        _paintMatrix(canvas, size, rain: true);
      case 'wave':
        _paintWave(canvas, size);
      case 'bars':
        _paintBars(canvas, size);
      case 'donut':
        _paintDonut(canvas, size);
      case 'fire':
        _paintFire(canvas, size);
      case 'starfield':
        _paintStarfield(canvas, size);
      case 'life':
        _paintLife(canvas, size);
      default:
        _paintMatrix(canvas, size, rain: false);
    }
  }

  void _paintMatrix(Canvas canvas, Size size, {required bool rain}) {
    final cell = (20 - intensity * .7).clamp(10, 20).toDouble() * resolution;
    final cols = (size.width / cell).ceil();
    final rows = (size.height / cell).ceil();
    const matrixChars =
        'ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ0123456789ABCDEF';
    const rainChars = 'ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿ0123456789';
    final chars = rain ? rainChars : matrixChars;
    for (var col = 0; col < cols; col++) {
      final seed = _hash(col, 91);
      final band = _bands[col * _bands.length ~/ math.max(cols, 1)];
      final fallSpeed = 4.5 + intensity * .45 + band * 8;
      final head = ((_time * fallSpeed + seed % (rows * 3)) % (rows + 28)) - 20;
      final trail = 8 + intensity * 2 + seed % 12;
      // Paint at most three paragraphs per column instead of one TextPainter
      // per cell. On the Xiaomi this cuts Matrix paragraph layouts from
      // roughly 10k/frame to under 200/frame.
      _paintMatrixRun(
        canvas,
        chars,
        col,
        head.floor(),
        0,
        0,
        trail,
        cell,
        rows,
        _tone(1),
        FontWeight.w700,
      );
      _paintMatrixRun(
        canvas,
        chars,
        col,
        head.floor(),
        1,
        3,
        trail,
        cell,
        rows,
        _tone(.75).withValues(alpha: .8),
        FontWeight.w500,
      );
      _paintMatrixRun(
        canvas,
        chars,
        col,
        head.floor(),
        4,
        trail - 1,
        trail,
        cell,
        rows,
        _tone(.45).withValues(alpha: .38),
        FontWeight.w400,
      );
    }
  }

  void _paintMatrixRun(
    Canvas canvas,
    String chars,
    int col,
    int head,
    int firstTail,
    int lastTail,
    int trail,
    double cell,
    int rows,
    Color color,
    FontWeight weight,
  ) {
    final firstVisible = firstTail.clamp(0, trail - 1);
    final lastVisible = lastTail.clamp(0, trail - 1);
    if (lastVisible < firstVisible) return;
    final topTail = math.min(lastVisible, head);
    final bottomTail = math.max(firstVisible, head - rows + 1);
    if (topTail < bottomTail) return;
    final glyphs = StringBuffer();
    for (var tail = topTail; tail >= bottomTail; tail--) {
      final row = head - tail;
      glyphs.write(chars[_hash(col, row + (_time * 5).floor()) % chars.length]);
      if (tail != bottomTail) glyphs.write('\n');
    }
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: glyphs.toString(),
        style: TextStyle(
          color: color,
          fontFamily: 'monospace',
          fontSize: cell * .82,
          height: 1.22,
          fontWeight: weight,
        ),
      ),
    )..layout(maxWidth: cell);
    painter.paint(canvas, Offset(col * cell, (head - topTail) * cell));
  }

  void _paintWave(Canvas canvas, Size size) {
    final center = size.height / 2;
    for (var layer = 0; layer < 3; layer++) {
      final path = Path();
      final amplitude =
          size.height * .18 * (.5 + _volume.clamp(0, 1)) * (1 - layer * .25);
      for (double x = 0; x <= size.width; x += 4) {
        final y =
            center +
            amplitude *
                math.sin(x * (.012 + layer * .005) + _time * (1 + layer * .6));
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2 + (2 - layer) * .8
          ..color = _tone(.8 - layer * .18, layer * 14).withValues(alpha: .8),
      );
    }
  }

  void _paintBars(Canvas canvas, Size size) {
    final width = size.width / _bands.length;
    for (var i = 0; i < _bands.length; i++) {
      final idle = .08 + .05 * math.sin(_time * 1.4 + i * .7);
      final energy = math.max(_bands[i] * 1.1, idle).clamp(0, 1);
      final height = energy * size.height * .9;
      final rect = Rect.fromLTWH(
        i * width + 2,
        size.height - height,
        math.max(1, width - 4),
        height,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [_tone(.35), _tone(.7, 18), _tone(1, 35)],
          ).createShader(rect),
      );
    }
  }

  void _paintDonut(Canvas canvas, Size size) {
    final a = _time * .8 * (1 + _volume * 2);
    final e = _time * .4 * (1 + _volume * 2);
    final z = <int, double>{};
    final points = List.generate(3, (_) => <Offset>[]);
    final step = .08 * math.sqrt(resolution);
    for (double j = 0; j < math.pi * 2; j += step * 1.8) {
      for (double i = 0; i < math.pi * 2; i += step) {
        final sj = math.sin(j), cj = math.cos(j);
        final si = math.sin(i), ci = math.cos(i);
        final sa = math.sin(a), ca = math.cos(a);
        final se = math.sin(e), ce = math.cos(e);
        final h = cj + 2;
        final depth = 1 / (si * h * sa + sj * ca + 5);
        final t = si * h * ca - sj * sa;
        final x =
            size.width / 2 + size.width * .38 * depth * (ci * h * ce - t * se);
        final y =
            size.height / 2 +
            size.height * .34 * depth * (ci * h * se + t * ce);
        final key = (x ~/ 8) * 10000 + y ~/ 14;
        if (x < 0 ||
            y < 0 ||
            x >= size.width ||
            y >= size.height ||
            depth <= (z[key] ?? 0)) {
          continue;
        }
        z[key] = depth;
        final lum =
            (((sj * sa - si * ca) * ce - ci * h * se - sj * ca - ci * h * sa) *
                    8)
                .clamp(0, 10)
                .floor();
        points[lum > 8 ? 0 : (lum > 4 ? 1 : 2)].add(Offset(x, y));
      }
    }
    for (var i = 0; i < points.length; i++) {
      canvas.drawPoints(
        ui.PointMode.points,
        points[i],
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = (4 - i).toDouble()
          ..color = _tone(1 - i * .24),
      );
    }
  }

  void _paintFire(Canvas canvas, Size size) {
    final cell = 14.0 * resolution;
    final cols = (size.width / cell).ceil();
    final rows = (size.height / cell).ceil();
    final paints = List.generate(
      3,
      (i) => Paint()
        ..color = HSVColor.fromAHSV(
          .8,
          10 + i * 20,
          .9,
          .45 + i * .22,
        ).toColor(),
    );
    for (var y = 0; y < rows; y++) {
      final normalized = 1 - y / rows;
      for (var x = 0; x < cols; x++) {
        final noise = _noise(x * .24, y * .18 - _time * 2.2);
        final lick = normalized + noise * .22 + _volume * .18;
        if (lick < .65) continue;
        final heat = ((lick - .65) * 2.8).clamp(0, 1);
        final paint = paints[(heat * 2).floor().clamp(0, 2)];
        canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell - 2, cell - 2),
          paint,
        );
      }
    }
  }

  void _paintStarfield(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final count = (100 + intensity * 12) ~/ math.sqrt(resolution);
    for (var i = 0; i < count; i++) {
      final angle = (_hash(i, 3) % 6283) / 1000;
      final phase = (_hash(i, 7) % 1000) / 1000;
      final depth =
          (phase + _time * (.08 + intensity * .006) * (1 + _volume * 2.2)) % 1;
      final radius = depth * depth * size.longestSide * .72;
      final p = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      final r = .6 + depth * 2.5;
      canvas.drawCircle(
        p,
        r,
        Paint()
          ..color = _tone(.4 + depth * .6).withValues(alpha: .3 + depth * .7),
      );
    }
  }

  void _paintLife(Canvas canvas, Size size) {
    final cell = 12.0 * resolution;
    final cols = (size.width / cell).ceil();
    final rows = (size.height / cell).ceil();
    final generation = (_time * (2 + intensity * .18 + _volume * 2)).floor();
    final paint = Paint();
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        // A deterministic cellular field with Conway-like travelling clusters;
        // stable for each generation and cheap enough for a launcher background.
        final neighbors = List<int>.generate(8, (i) {
          const dx = [-1, 0, 1, -1, 1, -1, 0, 1];
          const dy = [-1, -1, -1, 0, 0, 1, 1, 1];
          return _hash(
                        x + dx[i] + generation ~/ 3,
                        y + dy[i] - generation ~/ 5,
                      ) %
                      7 ==
                  0
              ? 1
              : 0;
        }).fold(0, (a, b) => a + b);
        final alive =
            neighbors == 3 ||
            (neighbors == 2 && _hash(x + generation, y) % 5 == 0);
        if (!alive) continue;
        paint.color = _tone(.45 + neighbors * .12).withValues(alpha: .75);
        canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell - 2, cell - 2),
          paint,
        );
      }
    }
  }

  double _noise(double x, double y) =>
      (math.sin(x * 1.7 + math.sin(y * .9)) +
              math.sin(y * 1.3 + math.cos(x * .7))) *
          .25 +
      .5;

  int _hash(int x, int y) {
    var h = x * 374761393 + y * 668265263;
    h = (h ^ (h >> 13)) * 1274126177;
    return (h ^ (h >> 16)).abs();
  }

  @override
  bool shouldRepaint(covariant TtfxBackgroundPainter oldDelegate) =>
      oldDelegate.effect != effect ||
      oldDelegate.intensity != intensity ||
      oldDelegate.speed != speed ||
      oldDelegate.resolution != resolution ||
      oldDelegate.reactivity != reactivity ||
      oldDelegate.accent != accent;
}
