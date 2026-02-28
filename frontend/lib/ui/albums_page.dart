import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/providers.dart';

class AlbumsPage extends ConsumerStatefulWidget {
  final String? artist;
  const AlbumsPage({super.key, this.artist});

  @override
  ConsumerState<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends ConsumerState<AlbumsPage> {
  @override
  Widget build(BuildContext context) {
    return const Center(child: Text("Albums"));
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(trackSyncProvider.notifier).sync());
  }
}
