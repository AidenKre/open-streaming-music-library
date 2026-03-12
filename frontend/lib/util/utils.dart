class Utils {
  static bool? parseBool(Object? value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is int) return value == 1;
    return null;
  }
}
