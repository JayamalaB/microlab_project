import 'package:flutter_test/flutter_test.dart';
import 'package:microlab/utils/dob_age.dart';

void main() {
  final today = DateTime(2026, 11, 26);

  group('ageFromDob', () {
    test('birthday already passed this year', () {
      expect(ageFromDob(DateTime(2007, 11, 26), today: today), 19);
    });
    test('birthday later this year', () {
      expect(ageFromDob(DateTime(2007, 12, 1), today: today), 18);
    });
    test('born this year is 0', () {
      expect(ageFromDob(DateTime(2026, 1, 5), today: today), 0);
    });
  });

  group('dobFromAge', () {
    test("today's day and month, age years back", () {
      expect(dobFromAge(19, today: today), DateTime(2007, 11, 26));
    });
    test('age 0 is today', () {
      expect(dobFromAge(0, today: today), today);
    });
    test('round trip gives the same age', () {
      for (final age in [0, 1, 25, 60, 120]) {
        expect(ageFromDob(dobFromAge(age, today: today), today: today), age);
      }
    });
  });

  test('formatDob is DD/MM/YYYY', () {
    expect(formatDob(DateTime(2007, 3, 5)), '05/03/2007');
  });
}
