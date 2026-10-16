import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter/services.dart';

import '../utils/api/opportunity_api.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import '../utils/widget/home_back_button.dart';
import 'opportunity_details_page.dart';

class MyOpportunitiesPage extends StatefulWidget {
  const MyOpportunitiesPage({super.key});

  @override
  State<MyOpportunitiesPage> createState() => _MyOpportunitiesPageState();
}

class _MyOpportunitiesPageState extends State<MyOpportunitiesPage> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = false;
  bool _hasMore = false;
  int _offset = 0;
  String? _error;
  final _search = TextEditingController();
  Timer? _searchDebounce;
  int _request = 0;

  @override
  void dispose() {
    _request++;
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _searchChanged(String _) {
    _searchDebounce?.cancel();
    _request++;
    setState(() {
      _items = [];
      _offset = 0;
      _hasMore = false;
      _error = null;
      _loading = true;
    });
    _searchDebounce = Timer(const Duration(milliseconds: 450), () => _load());
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more && _loading) return;
    _searchDebounce?.cancel();
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await OpportunityApi.getMyOpportunities(
        offset: more ? _offset : 0,
        phone: _search.text,
      );
      if (!mounted || request != _request) return;
      setState(() {
        final merged = <String, Map<String, dynamic>>{
          if (more)
            for (final item in _items) item['name'].toString(): item,
          for (final item in page) item['name'].toString(): item,
        };
        _items = merged.values.toList();
        _offset = (more ? _offset : 0) + page.length;
        _hasMore = page.length == OpportunityApi.pageSize;
      });
    } catch (error) {
      if (mounted && request == _request) {
        setState(() {
          _items = [];
          _offset = 0;
          _hasMore = false;
          _error = error.toString().replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF5F7FA),
    appBar: brandAppBar(
      leading: const HomeBackButton(color: Colors.white),
      title: const Text('My Opportunities'),
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            controller: _search,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(15),
            ],
            onChanged: _searchChanged,
            decoration: InputDecoration(
              hintText: 'Search by phone number',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon:
                  _search.text.isEmpty
                      ? null
                      : IconButton(
                        tooltip: 'Clear phone search',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _search.clear();
                          _searchChanged('');
                        },
                      ),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: BrandColors.ink,
            onRefresh: () => _load(),
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: _items.length + 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _error == null
                      ? const SizedBox.shrink()
                      : Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          children: [
                            Text(_error!, textAlign: TextAlign.center),
                            TextButton(
                              onPressed:
                                  _loading
                                      ? null
                                      : () => _load(
                                        more: _items.isNotEmpty && _hasMore,
                                      ),
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                }
                if (index == _items.length + 1) {
                  if (_loading) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: AgPathLoadingIndicator()),
                    );
                  }
                  if (_items.isEmpty && _error == null) {
                    return Padding(
                      padding: EdgeInsets.symmetric(vertical: 90),
                      child: Center(
                        child: Text(
                          _search.text.isEmpty
                              ? 'You have not created any opportunities yet.'
                              : 'No opportunities match this phone number.',
                        ),
                      ),
                    );
                  }
                  return _hasMore
                      ? TextButton(
                        onPressed: () => _load(more: true),
                        child: const Text('Load more'),
                      )
                      : const SizedBox.shrink();
                }
                final item = _items[index - 1];
                final name = item['name'].toString();
                final customerName =
                    item['customer_name']?.toString().trim() ?? '';
                final customer =
                    customerName.isNotEmpty
                        ? customerName
                        : (item['party_name']?.toString().trim() ?? '');
                return Card(
                  elevation: 0,
                  child: ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.handshake_outlined),
                    ),
                    title: Text(
                      customer.isEmpty ? name : customer,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text('$name\n${item['status'] ?? ''}'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap:
                        () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder:
                                (_) =>
                                    OpportunityDetailsPage(opportunityId: name),
                          ),
                        ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    ),
  );
}
