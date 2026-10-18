import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midipro/main.dart' show noteAtPosition;

void main() {
  test('maps two octaves to white and black piano notes', () {
    const size = Size(700, 200);

    expect(noteAtPosition(const Offset(25, 180), size, 48), 48); // C3
    expect(noteAtPosition(const Offset(50, 40), size, 48), 49); // C#3
    expect(noteAtPosition(const Offset(75, 180), size, 48), 50); // D3
    expect(noteAtPosition(const Offset(100, 40), size, 48), 51); // D#3
    expect(noteAtPosition(const Offset(150, 40), size, 48), 53); // F3
    expect(noteAtPosition(const Offset(375, 180), size, 48), 60); // C4
  });

  test('ignores touches outside the keyboard', () {
    const size = Size(700, 200);

    expect(noteAtPosition(const Offset(-1, 20), size, 48), isNull);
    expect(noteAtPosition(const Offset(700, 20), size, 48), isNull);
    expect(noteAtPosition(const Offset(20, 200), size, 48), isNull);
  });
}
