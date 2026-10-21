import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/reader_prefs.dart';
import 'package:inkbloom_reader/squishy.dart';

void main() {
  test('read-aloud default is slow enough to follow (0.6x)', () {
    expect(const ReaderSettings().ttsRate, 0.6);
    expect(ReaderSettings.fromJson({}).ttsRate, 0.6);
  });

  testWidgets('squishy shrinks on press and springs back', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Squishy(
          onTap: () => tapped = true,
          child: const Text('press me'),
        ),
      ),
    ));
    final gesture =
        await tester.startGesture(tester.getCenter(find.text('press me')));
    await tester.pump();
    final scaleDown = tester
        .widget<AnimatedScale>(find.byType(AnimatedScale))
        .scale;
    expect(scaleDown, lessThan(1.0));
    await gesture.up();
    await tester.pump();
    final scaleUp =
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
    expect(scaleUp, 1.0);
    expect(tapped, isTrue);
  });
}
