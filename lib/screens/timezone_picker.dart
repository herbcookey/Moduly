import 'package:flutter/material.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../core/timezone_utils.dart';

/// 정확한 IANA 시간대를 선택할 수 있는 간결하고 키보드 및 화면 읽기 프로그램 친화적인
/// 필드다. 값 자체를 항상 백엔드로 보내며 간격이나 약어로 대체하지 않는다.
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

/// 번들 시간대 데이터베이스에 있는 정확한 이름의 검색 가능 목록을 연다.
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
        // 번들 데이터베이스는 이 네임스페이스 아래에 생성된 별칭도 노출한다. 유효한
        // IANA 이름이지만 UTC와 Etc는 유지한 채 걸러 내면 작은 화면에서도 검색
        // 목록을 유용하게 쓸 수 있다.
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
    // 대화상자 제목/동작과 키보드 안전 여백을 위한 공간을 확보한다. 그 결과 작은
    // 표시 영역만 남아도 목록은 계속 스크롤할 수 있다.
    final availableHeight = media.size.height - media.viewInsets.bottom - 240;
    // 키보드 때문에 표시 영역이 매우 짧아져도 검색 필드를 사용할 수 있게 한다.
    // AlertDialog가 이 상자를 사용 가능한 높이로 더 제한하며, 128px이면 크기가 조정된
    // 검색 필드와 목록 일부가 들어간다.
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
