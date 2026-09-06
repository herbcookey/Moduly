import 'package:flutter/material.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../core/timezone_utils.dart';

/// A compact, keyboard- and screen-reader-friendly field for selecting an
/// exact IANA zone.  The value itself is always sent to the backend; no
/// offset or abbreviation is substituted.
class IanaTimezoneField extends StatelessWidget {
  const IanaTimezoneField({
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.labelText = '시간대 (IANA)',
    this.errorText,
    super.key,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final String labelText;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      button: true,
      enabled: enabled,
      label: '$labelText: $value',
      hint: enabled ? '탭하여 IANA 시간대를 검색하고 선택' : null,
      child: Tooltip(
        message: 'IANA 시간대 검색',
        child: InkWell(
          onTap: enabled
              ? () async {
                  final selected = await showIanaTimezonePicker(
                    context,
                    initialValue: value,
                  );
                  if (selected != null) onChanged(selected);
                }
              : null,
          borderRadius: BorderRadius.circular(4),
          child: InputDecorator(
            isEmpty: value.isEmpty,
            decoration: InputDecoration(
              labelText: labelText,
              errorText: errorText,
              suffixIcon: const Icon(Icons.search),
              enabled: enabled,
            ),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge,
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a searchable list of exact names from the bundled timezone database.
Future<String?> showIanaTimezonePicker(
  BuildContext context, {
  String? initialValue,
}) {
  _ensureTimezoneData();
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _TimezonePickerDialog(
      initialValue: initialValue,
      timezones: ianaTimezoneNames(),
    ),
  );
}

List<String> ianaTimezoneNames() {
  _ensureTimezoneData();
  final names = tz.timeZoneDatabase.locations.keys
      .where((name) {
        // The bundled database also exposes generated aliases under these
        // namespaces. They are valid IANA names, but filtering them keeps the
        // search list useful on a small screen while retaining UTC and Etc.
        return !name.startsWith('posix/') && !name.startsWith('right/');
      })
      .toSet()
      .toList();
  if (!names.contains(defaultPlannerTimezone)) {
    names.add(defaultPlannerTimezone);
  }
  names.sort((a, b) {
    if (a == defaultPlannerTimezone) return -1;
    if (b == defaultPlannerTimezone) return 1;
    return a.compareTo(b);
  });
  return List<String>.unmodifiable(names);
}

void _ensureTimezoneData() {
  if (!tz.timeZoneDatabase.isInitialized) tzdata.initializeTimeZones();
}

class _TimezonePickerDialog extends StatefulWidget {
  const _TimezonePickerDialog({required this.timezones, this.initialValue});

  final List<String> timezones;
  final String? initialValue;

  @override
  State<_TimezonePickerDialog> createState() => _TimezonePickerDialogState();
}

class _TimezonePickerDialogState extends State<_TimezonePickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (mounted) setState(() => _query = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final filtered = widget.timezones
        .where((zone) => query.isEmpty || zone.toLowerCase().contains(query))
        .toList(growable: false);
    final media = MediaQuery.of(context);
    // Reserve room for the dialog title/actions and keyboard-safe inset. The
    // list remains scrollable when this leaves only a compact viewport.
    final availableHeight = media.size.height - media.viewInsets.bottom - 240;
    // Keep the search field usable even when the keyboard leaves a very short
    // viewport.  AlertDialog will further constrain this box to the available
    // height; 128px fits the scaled search field and a sliver of list.
    final maxHeight = availableHeight.clamp(128.0, 520.0).toDouble();
    final maxWidth = (media.size.width - media.viewInsets.horizontal - 32)
        .clamp(200.0, 520.0)
        .toDouble();
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('시간대 선택'),
      content: SizedBox(
        width: maxWidth,
        height: maxHeight,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _searchController,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: '도시/지역 검색',
                hintText: '예: Asia/Seoul',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('일치하는 시간대가 없어요.'))
                  : ListView.builder(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final zone = filtered[index];
                        final selected = zone == widget.initialValue;
                        return Semantics(
                          button: true,
                          selected: selected,
                          label: '시간대 $zone',
                          child: ListTile(
                            minVerticalPadding: 14,
                            selected: selected,
                            title: Text(zone),
                            trailing: selected ? const Icon(Icons.check) : null,
                            onTap: () => Navigator.pop(context, zone),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
      ],
    );
  }
}
