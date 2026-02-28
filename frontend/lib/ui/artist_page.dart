import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/providers.dart';

class ArtistsPage extends ConsumerStatefulWidget {
  const ArtistsPage({super.key});

  @override
  ConsumerState<ArtistsPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends ConsumerState<ArtistsPage> {
  @override
  Widget build(BuildContext context) {
    return const Center(child: Text("Artists"));
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(trackSyncProvider.notifier).sync());
  }
}
