import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohm_launcher/ttfx_background.dart';

Future<Uint8List> _render(String effect, double clock) async {
  const size = ui.Size(320, 640);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final painter = TtfxBackgroundPainter(
    effect: effect,
    clock: AlwaysStoppedAnimation(clock),
    spectrum: ValueNotifier(const TtfxSpectrum.silent()),
    intensity: 5,
    speed: 1,
    resolution: 2,
    reactivity: 2,
    accent: const ui.Color(0xFF66E0FF),
  );
  painter.paint(canvas, size);
  final image = await recorder.endRecording().toImage(320, 640);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

void main() {
  for (final effect in TtfxBackground.nativeEffects) {
    test('TTFX $effect paints a non-empty frame', () async {
      final pixels = await _render(effect, 10);
      var lit = 0;
      for (var i = 0; i < pixels.length; i += 4) {
        if (pixels[i] + pixels[i + 1] + pixels[i + 2] > 24) {
          lit++;
        }
      }
      expect(
        lit,
        greaterThan(2),
        reason: '$effect rendered an empty background',
      );
    });
  }

  test('TTFX catalog exposes every real Rust effect', () {
    expect(TtfxBackground.ttfxEffects, hasLength(37));
    expect(
      TtfxBackground.ttfxEffects,
      containsAll(<String>[
        'beams',
        'blackhole',
        'fireworks',
        'laseretch',
        'synthgrid',
        'thunderstorm',
        'vhstape',
        'wipe',
      ]),
    );
  });

  test('TTFX uses framed output instead of a cursor-driven PTY', () {
    final args = buildTtfxFrameArgs(
      binaryPath: '/app/ttfx',
      inputPath: '/app/text',
      fps: 30,
      columns: 80,
      rows: 40,
      effect: 'rings',
    );
    expect(args.first, '/app/ttfx');
    expect(args, contains('--parity-dump'));
    expect(args, contains('--pace-dump'));
    expect(args, contains('--final-text-bands'));
    expect(args, isNot(contains('--reuse-canvas')));
  });

  test(
    'TTFX frame decoder handles arbitrary stream chunk boundaries',
    () async {
      final chunks = Stream<List<int>>.fromIterable([
        [53, 10, 104],
        [101, 108],
        [108, 111, 10, 53, 10, 119],
        [111, 114, 108, 100, 10],
      ]);

      expect(await decodeTtfxFrames(chunks).toList(), ['hello', 'world']);
    },
  );

  test('TTFX raster disables wrapping and resets every row', () {
    expect(ttfxRasterSequence('AB  \n  CD'), '\x1b[?7l\x1b[HAB  \r\n  CD');
  });

  test('TTFX visibility ignores ANSI parameters and whitespace', () {
    expect(ttfxVisibleGlyphCount('\x1b[38;2;149;25;149m   \x1b[0m'), 0);
    expect(ttfxVisibleGlyphCount('\x1b[38;2;149;25;149m█\x1b[0m'), 1);
  });

  test('Omarchy sizes 6 and 7 add detail without forcing max resolution', () {
    final small = officialOmarchyCellArt(120, 100, 1).split('\n');
    final large = officialOmarchyCellArt(120, 100, 7).split('\n');

    expect(small.first.length, 53);
    expect(large.first.length, 120);
    expect(large.length, greaterThan(small.length));
    expect(ttfxCanvasColumns(6, 'Omarchy', 5), 65);
    expect(ttfxCanvasColumns(6, 'Omarchy', 6), 75);
    expect(ttfxCanvasColumns(6, 'Omarchy', 7), 85);
    expect(large.join(), isNot(contains('▓')));
    expect(large.join(), isNot(contains('░')));
  });

  test(
    'Omarchy resolution changes bitmap density without changing its source',
    () {
      final detailed = officialOmarchyCellArt(120, 100, 3).split('\n');
      final fast = officialOmarchyCellArt(57, 100, 3).split('\n');

      expect(detailed.first.length, 84);
      expect(fast.first.length, 40);
      expect(detailed.length, greaterThan(fast.length));
      expect(detailed.join().contains('█'), isTrue);
      expect(fast.join().contains('█'), isTrue);
    },
  );

  test('TTFX matrix advances between frames', () async {
    final first = await _render('matrix', 10);
    final second = await _render('matrix', 10.5);
    var changed = 0;
    for (var i = 0; i < first.length; i += 4) {
      if (first[i] != second[i] ||
          first[i + 1] != second[i + 1] ||
          first[i + 2] != second[i + 2]) {
        changed++;
      }
    }
    expect(changed, greaterThan(20));
  });

  testWidgets('mini controls cycle effects and move text', (tester) async {
    var previous = 0;
    var next = 0;
    double? x;
    double? y;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: TtfxMiniControls(
            effect: 'beams',
            x: .5,
            y: .5,
            onPreviousEffect: () => previous++,
            onNextEffect: () => next++,
            onXChanged: (value) => x = value,
            onYChanged: (value) => y = value,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.auto_awesome));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.skip_previous));
    await tester.tap(find.byIcon(Icons.skip_next));
    await tester.drag(find.byType(Slider).at(0), const Offset(40, 0));
    await tester.drag(find.byType(Slider).at(1), const Offset(-40, 0));
    expect(previous, 1);
    expect(next, 1);
    expect(x, isNotNull);
    expect(y, isNotNull);
  });
}
