/// [one] when [n] is 1, else "[n] [many]": `countText(1, '1 event held
/// back', 'events held back')` reads "1 event held back", with 3 "3 events
/// held back". Shared by the "Sync & storage" rows.
String countText(int n, String one, String many) => n == 1 ? one : '$n $many';
