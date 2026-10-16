/// Presents transport failures without exposing URLs or socket diagnostics.
/// Does not probe connectivity, retry requests, or classify ERP errors offline.
class ConnectionNotice {
  const ConnectionNotice(this.title, this.message, {this.timedOut = false});

  final String title;
  final String message;
  final bool timedOut;

  static ConnectionNotice? fromError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('timeoutexception') ||
        text.contains('connection timed out') ||
        text.contains('connection timeout')) {
      return const ConnectionNotice(
        'Connection timed out',
        'The connection is taking too long. Check your internet connection and try again.',
        timedOut: true,
      );
    }
    if (text.contains('socketexception') ||
        text.contains('failed host lookup') ||
        text.contains('network is unreachable') ||
        text.contains('no internet connection') ||
        text.contains('no internet access') ||
        text.contains('net::err_internet_disconnected') ||
        text.contains('net::err_name_not_resolved') ||
        text.contains('clientexception: failed to fetch') ||
        text.contains('clientexception: connection closed') ||
        text.contains('clientexception: connection reset')) {
      return const ConnectionNotice(
        'No internet connection',
        'Turn on mobile data or connect to Wi-Fi, then try again.',
      );
    }
    return null;
  }
}
