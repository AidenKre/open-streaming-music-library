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

class AppInfo {
  final Map<String, EntityInfo> entities;

  const AppInfo({this.entities = const {}});

  EntityInfo? entity(String name) => entities[name];

  factory AppInfo.fromJson(Map<String, dynamic> json) {
    final rawEntities = (json['entities'] as Map<dynamic, dynamic>? ?? const {});
    return AppInfo(
      entities: rawEntities.map(
        (key, value) => MapEntry(
          key as String,
          EntityInfo.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'entities': entities.map((k, v) => MapEntry(k, v.toJson())),
  };
}
