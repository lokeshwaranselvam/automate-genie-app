/// Preserves the requested webpage. Local testing may route the configured
/// ERP origin through its same-origin proxy; other hosts are never replaced.
Uri? embeddedPageUri(
  String value, {
  required Uri app,
  String? site,
  String? proxyErpOrigin,
}) {
  final page = Uri.tryParse(value);
  final localSite = Uri.tryParse(site ?? '');
  final localApp =
      app.scheme == 'http' &&
      app.host == 'localhost' &&
      localSite != null &&
      localSite.hasAuthority &&
      localSite.origin == app.origin;
  if (page == null ||
      page.host.isEmpty ||
      page.userInfo.isNotEmpty ||
      (page.scheme != 'https' &&
          !(localApp && page.scheme == 'http' && page.origin == app.origin))) {
    return null;
  }
  final upstream = Uri.tryParse(proxyErpOrigin ?? '');
  if (localApp &&
      upstream != null &&
      upstream.scheme == 'https' &&
      upstream.userInfo.isEmpty &&
      upstream.host.isNotEmpty &&
      page.origin == upstream.origin) {
    return page.replace(scheme: app.scheme, host: app.host, port: app.port);
  }
  return page;
}
