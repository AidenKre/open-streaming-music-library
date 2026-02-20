abstract class IPaginatingListApi {
  Future<List<dynamic>> getInitialItems();

  Future<List<dynamic>> getNextItems();

  List<dynamic> getGottenItems();
}
