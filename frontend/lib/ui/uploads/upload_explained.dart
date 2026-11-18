import 'package:flutter/material.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

/// [child] (a control that is off because uploads are unavailable) with the
/// reason as its tooltip; [child] as is when uploads are available.
Widget explainedByAvailability(UploadsOverview overview, Widget child) =>
    overview.unavailableText == null
    ? child
    : Tooltip(message: overview.unavailableText!, child: child);
