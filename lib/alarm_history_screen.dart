import 'package:flutter/material.dart';

class AlarmHistoryScreen extends StatefulWidget {
  final List<Map<String, dynamic>> alarms;
  final List<Map<String, dynamic>> history;
  final Future<void> Function() onClearHistory;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(Map<String, dynamic>) onReAdd;
  final void Function(Map<String, dynamic>) onOpenMap;

  const AlarmHistoryScreen({
    super.key,
    required this.alarms,
    required this.history,
    required this.onClearHistory,
    required this.onToggleFavorite,
    required this.onReAdd,
    required this.onOpenMap,
  });

  @override
  State<AlarmHistoryScreen> createState() => _AlarmHistoryScreenState();
}

class _AlarmHistoryScreenState extends State<AlarmHistoryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  String _name(Map<String, dynamic> item) =>
      item['name']?.toString() ?? 'GeoAlarm';

  String _time(Map<String, dynamic> item) {
    final value = int.tryParse(item['timestamp']?.toString() ?? '');
    if (value == null) return 'Previous alarm';
    final date = DateTime.fromMillisecondsSinceEpoch(value);
    return '${date.day}/${date.month}/${date.year} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final favorites = widget.alarms
        .where((alarm) => alarm['favorite'] == true)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Alarm Library'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.favorite), text: 'Favorites'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Clear history',
            icon: const Icon(Icons.delete_outline),
            onPressed: widget.history.isEmpty
                ? null
                : () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Clear alarm history?'),
                        content: const Text(
                          'This will remove your saved alarm history.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await widget.onClearHistory();
                      if (mounted) setState(() {});
                    }
                  },
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildList(favorites, isHistory: false),
          _buildList(widget.history, isHistory: true),
        ],
      ),
    );
  }

  Widget _buildList(
    List<Map<String, dynamic>> items, {
    required bool isHistory,
  }) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          isHistory ? 'No alarm history yet.' : 'No favorite alarms yet.',
          style: const TextStyle(fontSize: 16),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              child: Icon(isHistory ? Icons.history : Icons.location_on),
            ),
            title: Text(_name(item)),
            subtitle: Text(isHistory ? _time(item) : 'Saved favorite location'),
            onTap: () => widget.onOpenMap(item),
            trailing: PopupMenuButton<String>(
              onSelected: (choice) async {
                if (choice == 'map') {
                  widget.onOpenMap(item);
                } else if (choice == 'favorite') {
                  await widget.onToggleFavorite(item);
                  if (mounted) setState(() {});
                } else if (choice == 'readd') {
                  await widget.onReAdd(item);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'map', child: Text('Open map')),
                if (!isHistory)
                  const PopupMenuItem(
                    value: 'favorite',
                    child: Text('Remove favorite'),
                  ),
                const PopupMenuItem(
                  value: 'readd',
                  child: Text('Add this alarm again'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
