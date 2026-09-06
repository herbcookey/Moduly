import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../repositories/schedule_repository.dart';
import 'timezone_picker.dart';

double _managementDialogHeight(BuildContext context) {
  final media = MediaQuery.of(context);
  return (media.size.height - media.viewInsets.bottom - 240)
      .clamp(120.0, 520.0)
      .toDouble();
}

double _managementDialogWidth(BuildContext context) {
  final media = MediaQuery.of(context);
  return (media.size.width - media.viewInsets.horizontal - 32)
      .clamp(180.0, 520.0)
      .toDouble();
}

class OwnerLeaveNotice extends StatelessWidget {
  const OwnerLeaveNotice({
    required this.onTransfer,
    required this.onArchive,
    super.key,
  });

  final VoidCallback? onTransfer;
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      const Text('소유자는 먼저 소유권을 이전하거나 그룹을 보관해야 합니다.'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          OutlinedButton.icon(
            onPressed: onTransfer,
            icon: const Icon(Icons.swap_horiz),
            label: const Text('소유권 이전'),
          ),
          OutlinedButton.icon(
            onPressed: onArchive,
            icon: const Icon(Icons.archive_outlined),
            label: const Text('그룹 보관'),
          ),
        ],
      ),
    ],
  );
}

class EditGroupDialog extends StatefulWidget {
  const EditGroupDialog({
    required this.group,
    required this.onSubmit,
    super.key,
  });

  final PlannerGroup group;
  final Future<void> Function(String name, String description, String timezone)
  onSubmit;

  @override
  State<EditGroupDialog> createState() => _EditGroupDialogState();
}

class _EditGroupDialogState extends State<EditGroupDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.group.name,
  );
  late final TextEditingController _descriptionController =
      TextEditingController(text: widget.group.description);
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late String _timezone = widget.group.timezone;
  String? _error;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      await widget.onSubmit(
        _nameController.text.trim(),
        _descriptionController.text.trim(),
        _timezone,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      final message = error is ScheduleConflictException
          ? error.message
          : error is ScheduleValidationException
          ? error.message
          : error is FormatException
          ? error.message
          : '그룹을 변경하지 못했어요. 최신 내용을 확인한 뒤 다시 시도해 주세요.';
      setState(() {
        _isSubmitting = false;
        _error = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dialogWidth = _managementDialogWidth(context);
    final dialogHeight = _managementDialogHeight(context);
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('그룹 정보 편집'),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextFormField(
                  controller: _nameController,
                  autofocus: true,
                  maxLength: 160,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  decoration: const InputDecoration(labelText: '그룹 이름'),
                  validator: (value) {
                    final name = value?.trim() ?? '';
                    if (name.isEmpty) return '그룹 이름을 입력해 주세요.';
                    if (name.length > 160) return '그룹 이름은 160자 이하로 입력해 주세요.';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                IanaTimezoneField(
                  value: _timezone,
                  enabled: !_isSubmitting,
                  onChanged: (value) => setState(() => _timezone = value),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  maxLines: 2,
                  maxLength: 10000,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(labelText: '설명 (선택)'),
                  validator: (value) => (value?.length ?? 0) > 10000
                      ? '설명은 10,000자 이하로 입력해 주세요.'
                      : null,
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Semantics(
                    liveRegion: true,
                    label: '오류: $_error',
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('저장'),
        ),
      ],
    );
  }
}

class TransferGroupDialog extends StatefulWidget {
  const TransferGroupDialog({
    required this.candidates,
    required this.onSubmit,
    super.key,
  });

  final List<PlannerMember> candidates;
  final Future<void> Function(String memberId) onSubmit;

  @override
  State<TransferGroupDialog> createState() => _TransferGroupDialogState();
}

class _TransferGroupDialogState extends State<TransferGroupDialog> {
  String? _selectedId;
  bool _confirming = false;
  bool _isSubmitting = false;
  String? _error;

  Future<void> _submit() async {
    final selected = _selectedId;
    if (selected == null || _isSubmitting) return;
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      await widget.onSubmit(selected);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      final message = error is ScheduleConflictException
          ? error.message
          : '소유권을 이전하지 못했어요. 최신 멤버 목록을 확인해 주세요.';
      setState(() {
        _isSubmitting = false;
        // Keep the selected target and the exact confirmation step visible
        // after a conflict. The parent controller reloads the group before
        // this callback returns, so the same confirmation can safely retry
        // with the freshly resolved version.
        if (error is! ScheduleConflictException) _confirming = false;
        _error = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.candidates
        .where((member) => member.id == _selectedId)
        .firstOrNull;
    final dialogWidth = _managementDialogWidth(context);
    final dialogHeight = _managementDialogHeight(context);
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(_confirming ? '소유권 이전을 확인할까요?' : '새 소유자 선택'),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: widget.candidates.isEmpty
            ? const Text('소유권을 이전할 수 있는 활성 멤버가 없어요.')
            : _confirming
            ? SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('${selected?.name ?? '선택한 멤버'}님에게 소유권을 이전합니다.'),
                    const SizedBox(height: 8),
                    const Text('이전 후에는 내가 소유자가 아니며 그룹 정보와 초대 코드를 관리할 수 없습니다.'),
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: 10),
                      Semantics(
                        liveRegion: true,
                        label: '오류: $_error',
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              )
            : RadioGroup<String>(
                groupValue: _selectedId,
                onChanged: _isSubmitting
                    ? (_) {}
                    : (value) => setState(() => _selectedId = value),
                child: ListView(
                  shrinkWrap: true,
                  children: widget.candidates
                      .map(
                        (member) => ListTile(
                          selected: member.id == _selectedId,
                          onTap: _isSubmitting
                              ? null
                              : () => setState(() => _selectedId = member.id),
                          leading: Radio<String>(value: member.id),
                          title: Text(member.name),
                          subtitle: member.email.isEmpty
                              ? null
                              : Text(member.email),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
      ),
      actions: widget.candidates.isEmpty
          ? <Widget>[
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('확인'),
              ),
            ]
          : <Widget>[
              TextButton(
                onPressed: _isSubmitting
                    ? null
                    : () {
                        if (_confirming) {
                          setState(() => _confirming = false);
                        } else {
                          Navigator.pop(context);
                        }
                      },
                child: Text(_confirming ? '이전 단계' : '취소'),
              ),
              FilledButton(
                onPressed:
                    _isSubmitting || (!_confirming && _selectedId == null)
                    ? null
                    : () {
                        if (_confirming) {
                          _submit();
                        } else {
                          setState(() => _confirming = true);
                        }
                      },
                child: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_confirming ? '소유권 이전' : '다음'),
              ),
            ],
    );
  }
}

class ArchiveGroupDialog extends StatefulWidget {
  const ArchiveGroupDialog({
    required this.groupName,
    required this.onSubmit,
    super.key,
  });

  final String groupName;
  final Future<void> Function() onSubmit;

  @override
  State<ArchiveGroupDialog> createState() => _ArchiveGroupDialogState();
}

class _ArchiveGroupDialogState extends State<ArchiveGroupDialog> {
  late final TextEditingController _controller = TextEditingController();
  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    if (_controller.text.trim() != widget.groupName) {
      setState(() => _error = '그룹 이름을 정확히 입력해 주세요.');
      return;
    }
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      await widget.onSubmit();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      final message = error is ScheduleConflictException
          ? error.message
          : '그룹을 보관하지 못했어요. 최신 내용을 확인한 뒤 다시 시도해 주세요.';
      setState(() {
        _isSubmitting = false;
        _error = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final exact = _controller.text.trim() == widget.groupName;
    final dialogWidth = _managementDialogWidth(context);
    final dialogHeight = _managementDialogHeight(context);
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('그룹을 보관할까요?'),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '보관하면 그룹이 모든 멤버의 목록에서 숨겨지고 복구할 수 없습니다. '
                '일정과 멤버 기록은 삭제되지 않지만 더 이상 사용할 수 없어요.',
              ),
              const SizedBox(height: 12),
              Text('계속하려면 그룹 이름 “${widget.groupName}”을 입력하세요.'),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                enabled: !_isSubmitting,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(labelText: '그룹 이름 확인'),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 10),
                Semantics(
                  liveRegion: true,
                  label: '오류: $_error',
                  child: Text(_error!, style: TextStyle(color: scheme.error)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _isSubmitting || !exact ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          child: _isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('그룹 보관'),
        ),
      ],
    );
  }
}
