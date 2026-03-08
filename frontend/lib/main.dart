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

  final _navigatorKeys = [
    GlobalKey<NavigatorState>(debugLabel: 'artists'),
    GlobalKey<NavigatorState>(debugLabel: 'albums'),
    GlobalKey<NavigatorState>(debugLabel: 'tracks'),
  ];

  Widget _buildTabNavigator(int index, Widget Function() rootBuilder) {
    return Navigator(
      key: _navigatorKeys[index],
      onGenerateRoute: (_) => MaterialPageRoute(
        builder: (_) => rootBuilder(),
      ),
    );
  }

  void _onTabTap(int index) {
    if (index == _tabIndex) {
      _navigatorKeys[index].currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _tabIndex = index);
      if (index == 2) _tracksKey.currentState?.sync();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final nav = _navigatorKeys[_tabIndex].currentState;
        if (nav != null && nav.canPop()) {
          nav.pop();
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tabIndex,
          children: [
            _buildTabNavigator(
              0,
              () => ArtistsPage(onDisconnect: widget.onDisconnect),
            ),
            _buildTabNavigator(
              1,
              () => AlbumsPage(onDisconnect: widget.onDisconnect),
            ),
            _buildTabNavigator(
              2,
              () => TracksPage(
                key: _tracksKey,
                onDisconnect: widget.onDisconnect,
              ),
            ),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _tabIndex,
          onTap: _onTabTap,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home), label: "Artists"),
            BottomNavigationBarItem(
              icon: Icon(Icons.library_music),
              label: "Albums",
            ),
            BottomNavigationBarItem(icon: Icon(Icons.search), label: "Tracks"),
          ],
        ),
      ),
    );
  }
}
