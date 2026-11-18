import 'package:flutter/material.dart';

/// The shell's tabs (phase-4 §3): Home first, then Search.
enum ShellTab {
  home('Home', Icons.home_outlined, Icons.home),
  search('Search', Icons.search, Icons.search);

  const ShellTab(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
