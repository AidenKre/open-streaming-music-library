/// The server's minimum password length (spec 5.1), in characters.
const minPasswordLength = 8;

/// Client-side checks for creating an account: a message to show, or null.
/// Length counts characters (runes), not UTF-16 units.
String? newAccountInputProblem(
  String username,
  String password,
  String confirmation,
) {
  if (username.trim().isEmpty) return 'Enter a username.';
  if (password.runes.length < minPasswordLength) {
    return 'Use at least $minPasswordLength characters for the password.';
  }
  if (password != confirmation) return 'The passwords do not match.';
  return null;
}

/// Client-side checks for logging in: a message to show, or null.
String? signInInputProblem(String username, String password) {
  if (username.trim().isEmpty || password.isEmpty) {
    return 'Enter your username and password.';
  }
  return null;
}
