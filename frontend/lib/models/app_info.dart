// Client mirror of the backend `GET /app/info` bootstrap blob. The home for
// app-global facts (editable fields now; later phases add e.g. conversion
// actions), cached client-side and consulted to decide what a user may edit.

class FieldDescriptor {
  final String key;
  final String label;

  /// Open string set (text/int/year/enum/bool now, `image` later for cover
  /// art) so a new type doesn't force a refactor of the form switch.
  final String valueType;
  final bool editable;

  const FieldDescriptor({
    required this.key,
    required this.label,
    required this.valueType,
    this.editable = true,
  });

  factory FieldDescriptor.fromJson(Map<String, dynamic> json) {
    return FieldDescriptor(
      key: json['key'] as String,
      label: json['label'] as String,
      valueType: json['valueType'] as String,
      editable: json['editable'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'label': label,
    'valueType': valueType,
    'editable': editable,
  };
}

class EntityInfo {
  final List<FieldDescriptor> fields;

  /// Non-mutation operations (e.g. a future master-type conversion). Empty in
  /// Phase 1; kept so later phases extend the blob rather than add endpoints.
  final List<String> actions;

  const EntityInfo({this.fields = const [], this.actions = const []});

  factory EntityInfo.fromJson(Map<String, dynamic> json) {
    final rawFields = (json['fields'] as List<dynamic>? ?? const []);
    final rawActions = (json['actions'] as List<dynamic>? ?? const []);
    return EntityInfo(
      fields: rawFields
          .map((f) => FieldDescriptor.fromJson(Map<String, dynamic>.from(f as Map)))
          .toList(),
      actions: rawActions.map((a) => a as String).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'fields': fields.map((f) => f.toJson()).toList(),
    'actions': actions,
  };
}

class ConversionTargetInfo {
  final String codec;
  final bool isLossless;

  const ConversionTargetInfo({required this.codec, required this.isLossless});

  factory ConversionTargetInfo.fromJson(Map<String, dynamic> json) {
    return ConversionTargetInfo(
      codec: json['codec'] as String,
      isLossless: json['is_lossless'] as bool,
    );
  }

  Map<String, dynamic> toJson() => {'codec': codec, 'is_lossless': isLossless};
}

class ConversionCapabilities {
  final List<ConversionTargetInfo> targets;
  final List<int> bitratePresets;

  const ConversionCapabilities({
    this.targets = const [],
    this.bitratePresets = const [],
  });

  /// Every target this build supports, minus the hard no-op (a lossless
  /// target that's the same codec as [sourceCodec]). Lossy same-codec stays
  /// in the list -- it's warn-only, not blocked server-side either. This is
  /// the client-side "per-track allowed target list" the backend doc
  /// deliberately keeps out of the cached bootstrap blob: computed live from
  /// this global list + the track's own (already-synced) source codec.
  List<ConversionTargetInfo> allowedFor(String? sourceCodec) {
    if (sourceCodec == null) return targets;
    return targets
        .where((t) => !(t.isLossless && t.codec == sourceCodec))
        .toList();
  }

  factory ConversionCapabilities.fromJson(Map<String, dynamic> json) {
    final rawTargets = (json['targets'] as List<dynamic>? ?? const []);
    final rawPresets = (json['bitrate_presets'] as List<dynamic>? ?? const []);
    return ConversionCapabilities(
      targets: rawTargets
          .map((t) => ConversionTargetInfo.fromJson(Map<String, dynamic>.from(t as Map)))
          .toList(),
      bitratePresets: rawPresets.map((p) => p as int).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'targets': targets.map((t) => t.toJson()).toList(),
    'bitrate_presets': bitratePresets,
  };
}

class AppInfo {
  final Map<String, EntityInfo> entities;
  final ConversionCapabilities conversion;

  const AppInfo({
    this.entities = const {},
    this.conversion = const ConversionCapabilities(),
  });

  EntityInfo? entity(String name) => entities[name];

  factory AppInfo.fromJson(Map<String, dynamic> json) {
    final rawEntities = (json['entities'] as Map<dynamic, dynamic>? ?? const {});
    final rawConversion = json['conversion'] as Map<dynamic, dynamic>?;
    return AppInfo(
      entities: rawEntities.map(
        (key, value) => MapEntry(
          key as String,
          EntityInfo.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      ),
      conversion: rawConversion != null
          ? ConversionCapabilities.fromJson(Map<String, dynamic>.from(rawConversion))
          : const ConversionCapabilities(),
    );
  }

  Map<String, dynamic> toJson() => {
    'entities': entities.map((k, v) => MapEntry(k, v.toJson())),
    'conversion': conversion.toJson(),
  };
}
