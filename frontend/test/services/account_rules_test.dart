// Phase M §7.1: confirm-match and minimum length are checked client-side
// (a model rule, SC-26; the server's 8–1024 NFC characters stay
// authoritative, §5.1).
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/account_rules.dart';

void main() {
  group('newAccountInputProblem', () {
    test('a valid username, an 8-character password and its match pass', () {
      expect(newAccountInputProblem('sam', '12345678', '12345678'), isNull);
    });

    test('7 characters are refused, naming the minimum', () {
      final problem = newAccountInputProblem('sam', '1234567', '1234567');
      expect(problem, isNotNull);
      expect(problem, contains('$minPasswordLength'));
    });

    test('length counts characters, not UTF-16 code units', () {
      const seven = '😀😀😀😀😀😀😀'; // 7 characters, 14 code units
      expect(newAccountInputProblem('sam', seven, seven), isNotNull);
      const eight = '😀😀😀😀😀😀😀😀';
      expect(newAccountInputProblem('sam', eight, eight), isNull);
    });

    test('a confirmation that does not match is refused', () {
      expect(newAccountInputProblem('sam', '12345678', '12345679'),
          contains('match'));
    });

    test('a blank username is refused', () {
      expect(newAccountInputProblem('  ', '12345678', '12345678'), isNotNull);
    });
  });

  group('signInInputProblem', () {
    test('both fields filled pass (length is the server\'s to judge)', () {
      expect(signInInputProblem('sam', 'x'), isNull);
    });

    test('an empty username or password is refused', () {
      expect(signInInputProblem('', 'secret-pw'), isNotNull);
      expect(signInInputProblem('sam', ''), isNotNull);
    });
  });
}
