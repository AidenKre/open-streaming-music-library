import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/artist_page.dart';
import 'package:frontend/ui/startup_gate.dart';
import 'package:frontend/ui/tracks_page.dart';

void main() => runApp(ProviderScope(child: Frontend()));

class Frontend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OSML',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const StartupGate(),
    );
  }
}

class AppShell extends ConsumerStatefulWidget {
  final VoidCallback onDisconnect;

  const AppShell({super.key, required this.onDisconnect});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _tabIndex = 0;
  final _tracksKey = GlobalKey<TracksPageState>();

  late final _tabs = [ArtistsPage(), AlbumsPage(), TracksPage(key: _tracksKey)];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OSML'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Disconnect',
            onPressed: widget.onDisconnect,
          ),
        ],
      ),
      body: IndexedStack(index: _tabIndex, children: _tabs),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: (i) {
          setState(() => _tabIndex = i);
          if (i == 2) _tracksKey.currentState?.sync();
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: "Artists"),
          BottomNavigationBarItem(
            icon: Icon(Icons.library_music),
            label: "Albums",
          ),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: "Tracks"),
        ],
      ),
    );
  }
}
