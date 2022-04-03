import 'dart:async';

import 'package:adaptive_dialog/adaptive_dialog.dart';
import 'package:every_door/models/amenity.dart';
import 'package:every_door/models/field.dart';
import 'package:every_door/models/preset.dart';
import 'package:every_door/providers/changes.dart';
import 'package:every_door/providers/need_update.dart';
import 'package:every_door/providers/presets.dart';
import 'package:every_door/screens/editor/map_chooser.dart';
import 'package:every_door/helpers/tile_layers.dart';
import 'package:every_door/screens/editor/tags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

class PoiEditorPage extends ConsumerStatefulWidget {
  final OsmChange? amenity; // OsmElement???
  final Preset? preset;
  final LatLng? location;

  const PoiEditorPage({this.amenity, this.preset, this.location});

  @override
  _PoiEditorPageState createState() => _PoiEditorPageState();
}

class _PoiEditorPageState extends ConsumerState<PoiEditorPage> {
  late OsmChange amenity;
  Preset? preset;
  List<PresetField> fields = []; // actual fields
  List<PresetField> moreFields = [];
  List<PresetField> stdFields = [];

  @override
  void initState() {
    super.initState();
    amenity = widget.amenity?.copy() ??
        OsmChange(null,
            newLocation: widget.location, newTags: widget.preset!.addTags);
    amenity.addListener(onAmenityChange);

    if (widget.preset == null) {
      updatePreset(context, true);
    } else {
      // Preset and location should not be null
      preset = widget.preset!;
      updatePreset(context, preset!.fromNSI);
    }
  }

  @override
  dispose() {
    amenity.removeListener(onAmenityChange);
    super.dispose();
  }

  onAmenityChange() {
    setState(() {});
  }

  updatePreset(BuildContext context, [bool detect = false]) async {
    await Future.delayed(Duration.zero); // to disconnect from initState
    final presets = ref.read(presetProvider);
    final locale = Localizations.localeOf(context);
    if (preset == null) detect = true;
    bool needRefresh = false;
    if (detect) {
      final newPreset = await presets.getPresetForTags(
        amenity.getFullTags(true),
        isArea: amenity.isArea,
        locale: locale,
      );
      if (preset == null || preset?.id != newPreset.id) {
        preset = newPreset;
        needRefresh = true;
      }
    }
    // print('Detected ($detect) preset $preset');
    if (preset!.fields.isEmpty) {
      preset = await presets.getFields(preset!, locale: locale);
      final bool needsStdFields =
          preset!.fields.length <= 1 || needsStandardFields();
      stdFields = await presets.getStandardFields(locale, needsStdFields);
      needRefresh = true;
    }
    if (needRefresh) {
      setState(() {
        extractFields();
      });
    }
  }

  bool needsStandardFields() {
    if (preset!.isFixme) return true;
    Set<String> allFields =
        (preset!.fields + preset!.moreFields).map((e) => e.key).toSet();
    return allFields.contains('opening_hours') && allFields.contains('phone');
  }

  extractFields() {
    final hasStdFields = stdFields.map((e) => e.key).toSet();
    hasStdFields.remove('internet_access');
    try {
      fields =
          preset!.fields.where((f) => !hasStdFields.contains(f.key)).toList();
    } on StateError {
      fields = [];
    }
    final tags = amenity.getFullTags();
    for (final f in preset!.moreFields) {
      if (hasStdFields.contains(f.key)) continue;
      if (f.hasRelevantKey(tags) || f.meetsPrerequisite(tags)) {
        fields.add(f);
      } else {
        moreFields.add(f);
      }
    }
  }

  saveAndClose() {
    // Setting the mark automatically.
    amenity.check();
    final changes = ref.read(changesProvider);
    changes.saveChange(amenity);
    Navigator.pop(context);
    ref.read(needMapUpdateProvider).trigger();
  }

  deleteAndClose() {
    final changes = ref.read(changesProvider);
    if (amenity.isNew) {
      changes.deleteChange(amenity);
    } else {
      amenity.deleted = true;
      changes.saveChange(amenity);
    }
    Navigator.pop(context);
    ref.read(needMapUpdateProvider).trigger();
  }

  @override
  Widget build(BuildContext context) {
    final preset = this.preset;
    final bool canSave = widget.amenity == null || amenity != widget.amenity;
    final loc = AppLocalizations.of(context)!;
    return WillPopScope(
      onWillPop: () async {
        if (!canSave)
          return true;
        else {
          final result = await showOkCancelAlertDialog(
            context: context,
            isDestructiveAction: true,
            title: 'Close the editor?',
            message: 'You will lose your unsaved changes. Proceed?',
          );
          return result == OkCancelResult.ok;
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(preset?.name ?? amenity.name ?? 'Editor'),
          actions: [
            IconButton(
              icon: Icon(Icons.table_rows),
              onPressed: () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => TagEditorPage(amenity)));
                // Expect the amenity to change.
                setState(() {});
              },
            ),
          ],
        ),
        body: preset == null
            ? Center(child: Text(loc.editorLoadingPreset))
            : Column(
                children: [
                  Expanded(
                    child: ListView(
                      children: [
                        if (amenity.canDelete) buildMap(context),
                        if (!amenity.canDelete) SizedBox(height: 10.0),
                        if (stdFields.isNotEmpty) ...[
                          buildFields(stdFields, 50),
                          SizedBox(height: 10.0),
                          Divider(),
                          SizedBox(height: 10.0),
                        ],
                        if (fields.isNotEmpty) ...[
                          buildFields(fields),
                          SizedBox(height: 20.0),
                        ],
                        buildTopButtons(context),
                        SizedBox(height: 10.0),
                        if (moreFields.isNotEmpty) ...[
                          ExpansionTile(
                            title: Text(loc.editorMoreFields),
                            initiallyExpanded: false,
                            children: [
                              buildFields(moreFields),
                            ],
                          ),
                          SizedBox(height: 30.0),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    height: 50.0,
                    child: MaterialButton(
                      color: Colors.green,
                      textColor: Colors.white,
                      disabledColor: Colors.white,
                      disabledTextColor: Colors.grey,
                      child: Text(
                        loc.editorSave,
                        style: TextStyle(fontSize: 20.0),
                      ),
                      onPressed: canSave ? saveAndClose : null,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget buildTopButtons(context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      padding: EdgeInsets.only(right: 5.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          MaterialButton(
            color: amenity.isDisused ? Colors.brown : Colors.orange,
            textColor: Colors.white,
            child: Text(amenity.isDisused
                ? loc.editorMarkActive
                : loc.editorMarkDefunct),
            onPressed: () {
              setState(() {
                amenity.toggleDisused();
              });
            },
          ),
          // Not displaying the deletion button for just created amenities.
          if (widget.amenity != null) ...[
            SizedBox(width: 10.0),
            MaterialButton(
              color: Colors.red,
              textColor: Colors.white,
              child:
                  Text(amenity.deleted ? loc.editorRestore : loc.editorMissing),
              onPressed: () async {
                if (amenity.deleted) {
                  setState(() {
                    amenity.deleted = false;
                  });
                } else {
                  final answer = await showOkCancelAlertDialog(
                    context: context,
                    title: loc.editorDeleteTitle(amenity.typeAndName),
                    okLabel: loc.editorDeleteButton,
                    isDestructiveAction: true,
                  );
                  if (answer == OkCancelResult.ok) {
                    deleteAndClose();
                  }
                }
              },
            ),
          ]
        ],
      ),
    );
  }

  Widget buildMap(BuildContext context) {
    return SizedBox(
      height: 100.0,
      child: FlutterMap(
        options: MapOptions(
          center: amenity.location,
          zoom: 17,
          interactiveFlags: 0,
          onTap: (pos, center) async {
            final newLocation = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    MapChooserPage(location: amenity.location),
              ),
            );
            if (newLocation != null) {
              setState(() {
                amenity.location = newLocation;
              });
            }
          },
        ),
        children: [
          TileLayerWidget(options: buildTileLayerOptions(kOSMImagery)),
          MarkerLayerWidget(
              options: MarkerLayerOptions(markers: [
            Marker(
              point: amenity.location,
              anchorPos: AnchorPos.exactly(Anchor(15.0, 5.0)),
              builder: (ctx) => Icon(Icons.location_pin),
            ),
          ])),
        ],
      ),
    );
  }

  Widget buildFields(List<PresetField> fields, [double labelWidth = 150]) {
    final List<Widget> rows = [];
    final tags = amenity.getFullTags();
    const kMandatoryKeys = {
      'opening_hours',
      'level',
      'addr',
      'internet_access',
      'wheelchair',
      'phone',
      'payment'
    };
    for (final field in fields) {
      bool hasTags = field.hasRelevantKey(tags);
      bool isMandatory = kMandatoryKeys.contains(field.key);
      rows.add(Row(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Flexible(fit: FlexFit.loose, flex: 2, child: Text(fields[index].label)),
          SizedBox(
            width: labelWidth,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: labelWidth >= 100
                  ? Text(field.label)
                  : Icon(
                      field.icon ?? Icons.sms,
                      color: !isMandatory
                          ? null
                          : (hasTags ? Colors.green : Colors.red.shade800),
                    ),
            ),
          ),
          // SizedBox(width: 5.0),
          Expanded(
            flex: 3,
            child: field.buildWidget(amenity),
          ),
        ],
      ));
    }

    return Column(children: rows);
  }
}
