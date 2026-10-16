import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:microlab/models.dart';
import 'package:microlab/services/api_service.dart';

// Loads the test/package catalog one page at a time from GET /api/tests,
// with the search done on the server — used by the pickers that would
// otherwise download all ~1,000 products (checkout's family-member sheet,
// My Bookings' edit-tests sheet).
//
// Typical use: call refresh() once, setSearch() from the search field, and
// wrap the list in a NotificationListener<ScrollNotification> that calls
// onScroll() so the next page loads near the end. Listen for changes with
// addListener / ListenableBuilder.
class PackagePager extends ChangeNotifier {
  PackagePager({this.pageSize = 20});

  final int pageSize;

  List<TestModel> items = [];
  int  total = 0;
  bool hasMore = false;
  bool loading = false;
  bool loadingMore = false;
  bool failed = false;
  String search = '';

  // Bumped on every new search, so a slow reply for an older search can't
  // overwrite the results of the current one.
  int _requestId = 0;
  Timer? _debounce;
  bool _disposed = false;

  // Called by the search field: asks the server once typing pauses.
  void setSearch(String text) {
    if (text == search) return;
    search = text;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), refresh);
  }

  // First page for the current search.
  Future<void> refresh() async {
    _debounce?.cancel();
    final requestId = ++_requestId;
    loading = true;
    loadingMore = false;
    failed = false;
    _notify();
    try {
      final page = await ApiService.getPackagesPage(search: search, limit: pageSize);
      if (_disposed || requestId != _requestId) return;
      items   = page.items;
      total   = page.total;
      hasMore = page.hasMore;
    } catch (e) {
      debugPrint('[PackagePager] first page failed: $e');
      if (_disposed || requestId != _requestId) return;
      failed = true;
    }
    loading = false;
    _notify();
  }

  // Next page for the current search.
  Future<void> loadMore() async {
    if (loading || loadingMore || !hasMore) return;
    final requestId = _requestId;
    loadingMore = true;
    _notify();
    try {
      final page = await ApiService.getPackagesPage(
        search: search, limit: pageSize, offset: items.length,
      );
      if (_disposed || requestId != _requestId) return;
      final have = items.map((t) => t.id).toSet();
      items   = [...items, ...page.items.where((t) => !have.contains(t.id))];
      total   = page.total;
      hasMore = page.hasMore;
    } catch (e) {
      debugPrint('[PackagePager] next page failed: $e');
    }
    if (_disposed || requestId != _requestId) return;
    loadingMore = false;
    _notify();
  }

  // Hook for NotificationListener<ScrollNotification>: start the next page
  // while a couple of rows are still below the visible area.
  bool onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 300) loadMore();
    return false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    super.dispose();
  }
}
