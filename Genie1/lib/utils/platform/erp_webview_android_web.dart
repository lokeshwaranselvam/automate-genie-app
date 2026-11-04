// Android-only picker contracts; browsers use the HTML file input directly.
enum FileSelectorMode { open, openMultiple, save }
class FileSelectorParams {
  const FileSelectorParams({this.mode = FileSelectorMode.open, this.acceptTypes = const [], this.isCaptureEnabled = false});
  final FileSelectorMode mode;
  final List<String> acceptTypes;
  final bool isCaptureEnabled;
}
class AndroidWebViewController {
  Future<void> setOnShowFileSelector(Future<List<String>> Function(FileSelectorParams) callback) async {}
}
