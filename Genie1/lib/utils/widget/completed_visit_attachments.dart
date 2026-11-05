import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../Screen/session_webview.dart';
import '../api/event.dart';
import '../platform/erp_web_page_uri.dart';

/// Saved Event files; fetching these never changes checkout or report data.
class CompletedVisitAttachments extends StatefulWidget {
  const CompletedVisitAttachments({
    super.key,
    required this.eventId,
    this.onImageCountLoaded,
  });
  final String eventId;
  final ValueChanged<int>? onImageCountLoaded;

  @override
  State<CompletedVisitAttachments> createState() =>
      _CompletedVisitAttachmentsState();
}

class _CompletedVisitAttachmentsState extends State<CompletedVisitAttachments> {
  List<Map<String, dynamic>>? _files;
  Map<String, String> _headers = {};
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _files = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      final report = await Event.getVisitReport(
        widget.eventId,
      ).timeout(const Duration(seconds: 20));
      if (prefs.getString('token') != token) {
        throw StateError('Session changed.');
      }
      final records = report['attachments'];
      if (records is! List || report['event_id'] != widget.eventId) {
        throw const FormatException('Attachment details are unavailable.');
      }
      final base = Uri.tryParse(dotenv.env['SITE_URL']?.trim() ?? '');
      if (base == null || !isTrustedErpPageUri(base)) {
        throw StateError('ERP URL unavailable.');
      }
      final files = <Map<String, dynamic>>[];
      for (final record in records.whereType<Map>()) {
        final path = record['file_url']?.toString().trim() ?? '';
        if (path.isEmpty) continue;
        var uri = base.resolve(path);
        // Absolute ERP file URLs must also travel through the local session
        // proxy. Map only its configured HTTPS upstream, never arbitrary hosts.
        final upstream = Uri.tryParse(dotenv.env['WEB_PROXY_ERP_ORIGIN'] ?? '');
        if (kIsWeb &&
            base.scheme == 'http' &&
            (base.host == 'localhost' || base.host == '127.0.0.1') &&
            upstream != null &&
            upstream.scheme == 'https' &&
            upstream.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            uri.origin == upstream.origin) {
          uri = base.replace(
            path: uri.path,
            query: uri.query,
            fragment: uri.fragment,
          );
        }
        // Never send ERP authentication to a different host or URL scheme.
        if (uri.origin != base.origin || uri.userInfo.isNotEmpty) {
          continue;
        }
        files.add({
          ...Map<String, dynamic>.from(record),
          'file_url': uri.toString(),
        });
      }
      if (mounted) {
        setState(() {
          _files = files;
          _headers = {if (token != null) 'Authorization': token};
        });
        widget.onImageCountLoaded?.call(
          files.where((file) => _isImage(file['file_url'] as String)).length,
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load visit attachments.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _isImage(String url) => RegExp(
    r'\.(jpe?g|png|gif|webp|bmp)$',
    caseSensitive: false,
  ).hasMatch(Uri.parse(url).path);

  void _open(Map<String, dynamic> file) {
    final url = file['file_url'] as String;
    final name = file['file_name']?.toString() ?? 'Visit attachment';
    if (_isImage(url)) {
      showDialog<void>(
        context: context,
        builder:
            (context) => Dialog(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                  Flexible(
                    child: InteractiveViewer(
                      child: Image.network(
                        url,
                        headers: _headers,
                        errorBuilder:
                            (_, __, ___) => const Padding(
                              padding: EdgeInsets.all(20),
                              child: Text('Could not open this image.'),
                            ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SessionWebView(url: url, title: name),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Attachments${_files == null ? '' : ' (${_files!.length})'}',
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w800,
          color: Color(0xFF202B3C),
        ),
      ),
      const SizedBox(height: 10),
      if (_loading)
        const LinearProgressIndicator()
      else if (_error != null)
        Row(
          children: [
            Expanded(child: Text(_error!)),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        )
      else if (_files?.isEmpty ?? true)
        const Text('No attachments yet')
      else
        for (final file in _files!)
          if (_isImage(file['file_url'] as String))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Semantics(
                label: 'Open visit photo',
                button: true,
                child: InkWell(
                  onTap: () => _open(file),
                  borderRadius: BorderRadius.circular(8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      file['file_url'] as String,
                      headers: _headers,
                      width: 82,
                      height: 82,
                      fit: BoxFit.cover,
                      errorBuilder:
                          (_, __, ___) => const SizedBox(
                            width: 82,
                            height: 82,
                            child: Icon(Icons.broken_image_outlined),
                          ),
                    ),
                  ),
                ),
              ),
            )
          else
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.attach_file),
              title: Text(
                file['file_name']?.toString() ?? 'Visit attachment',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () => _open(file),
            ),
    ],
  );
}
