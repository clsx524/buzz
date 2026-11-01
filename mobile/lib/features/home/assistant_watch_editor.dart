import 'dart:convert';

import 'package:flutter/material.dart';

import '../../shared/assistant/assistant_client.dart';
import 'assistant_value_view.dart';

class AssistantWatchEditor extends StatefulWidget {
  const AssistantWatchEditor({
    required this.client,
    required this.connection,
    this.watch,
    super.key,
  });
  final AssistantClient client;
  final AssistantConnection connection;
  final AssistantWatch? watch;
  @override
  State<AssistantWatchEditor> createState() => _AssistantWatchEditorState();
}

class _AssistantWatchEditorState extends State<AssistantWatchEditor> {
  final _form = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{};
  final _conditions = <Map<String, dynamic>>[];
  List<AssistantJson>? _tools;
  String? _error;
  AssistantJson? _preview;
  bool _busy = false;
  bool _enabled = true;
  bool _cron = false;
  String _mode = 'digest';
  String _tool = '';
  Map<String, dynamic> get _original => widget.watch?.definition ?? {};
  TextEditingController field(String key) => _fields[key]!;

  @override
  void initState() {
    super.initState();
    final d = _original;
    final attention = d['attention'] as Map? ?? {};
    final defaults = <String, String>{
      'id': '${d['id'] ?? ''}',
      'title': '${d['title'] ?? ''}',
      'interval': '${d['interval_seconds'] ?? 900}',
      'cron': '${d['cron'] ?? ''}',
      'timezone': '${d['timezone'] ?? 'UTC'}',
      'interest': '${d['interest'] ?? ''}',
      'ignore': (d['ignore'] as List? ?? []).join('\n'),
      'digest': '${attention['digest_seconds'] ?? 3600}',
      'quiet_start': '${attention['quiet_start'] ?? ''}',
      'quiet_end': '${attention['quiet_end'] ?? ''}',
      'attention_timezone': '${attention['timezone'] ?? 'UTC'}',
      'arguments': const JsonEncoder.withIndent(
        '  ',
      ).convert(d['arguments'] ?? {}),
      'mapping': const JsonEncoder.withIndent('  ').convert({
        for (final key in ['result', 'pagination', 'changes', 'baseline'])
          if (d.containsKey(key)) key: d[key],
      }),
    };
    for (final e in defaults.entries) {
      _fields[e.key] = TextEditingController(text: e.value);
    }
    _tool = '${d['tool'] ?? ''}';
    _enabled = d['enabled'] as bool? ?? true;
    _cron = d['cron'] != null;
    _mode = '${attention['mode'] ?? 'digest'}';
    for (final c in d['conditions'] as List? ?? []) {
      _conditions.add(Map<String, dynamic>.from(c as Map));
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              '$error. If a save failed, acceptance may be unknown. Return to the dashboard and refresh before explicitly trying again; no action is automatically retried.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _object(String key) {
    final decoded = jsonDecode(field(key).text);
    if (decoded is! Map) throw FormatException('$key must be a JSON object.');
    return Map<String, dynamic>.from(decoded);
  }

  AssistantJson _definition() {
    if (!_form.currentState!.validate()) {
      throw const FormatException('Please correct the highlighted fields.');
    }
    if (_tool.isEmpty) {
      throw const FormatException('Load approved sources and choose a source.');
    }
    final mapping = _object('mapping');
    if (mapping.keys.any(
      (k) => !['result', 'pagination', 'changes', 'baseline'].contains(k),
    )) {
      throw const FormatException(
        'Data mapping supports result, pagination, changes and baseline only.',
      );
    }
    final d = <String, dynamic>{..._original};
    for (final key in [
      'interval_seconds',
      'cron',
      'result',
      'pagination',
      'changes',
      'baseline',
    ]) {
      d.remove(key);
    }
    d.addAll({
      'id': field('id').text.trim(),
      'title': field('title').text.trim(),
      'tool': _tool,
      'arguments': _object('arguments'),
      'read_only': true,
      'enabled': _enabled,
      if (_cron)
        'cron': field('cron').text.trim()
      else
        'interval_seconds': int.parse(field('interval').text),
      'timezone': field('timezone').text.trim(),
      'interest': field('interest').text.trim(),
      'ignore': field('ignore').text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      'conditions': _conditions,
      'attention': {
        'mode': _mode,
        'digest_seconds': int.parse(field('digest').text),
        'timezone': field('attention_timezone').text.trim(),
        if (field('quiet_start').text.isNotEmpty)
          'quiet_start': field('quiet_start').text,
        if (field('quiet_end').text.isNotEmpty)
          'quiet_end': field('quiet_end').text,
      },
      ...mapping,
    });
    return d;
  }

  Widget _text(
    String key,
    String label, {
    int lines = 1,
    bool required = false,
    bool number = false,
    String? help,
    bool enabled = true,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextFormField(
      controller: field(key),
      decoration: InputDecoration(labelText: label, helperText: help),
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 6,
      enabled: enabled && !_busy,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      validator: (value) {
        if (required && (value == null || value.trim().isEmpty)) {
          return 'Required';
        }
        if (number && (int.tryParse(value ?? '') ?? 0) <= 0) {
          return 'Enter a positive whole number';
        }
        if (key == 'interest' && (value?.length ?? 0) > 2400) {
          return 'Maximum 2400 characters';
        }
        if (['quiet_start', 'quiet_end'].contains(key) &&
            value != null &&
            value.isNotEmpty &&
            !RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(value)) {
          return 'Use HH:MM (24-hour)';
        }
        return null;
      },
    ),
  );

  Future<void> _loadTools() => _run(() async {
    final response = await widget.client.command(widget.connection, {
      'resource': 'observer',
      'action': 'tools',
    });
    final tools = (response['tools'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (mounted) setState(() => _tools = tools);
  });

  Future<void> _condition([int? index]) async {
    final result = await showDialog<AssistantJson>(
      context: context,
      builder: (_) =>
          _ConditionDialog(value: index == null ? null : _conditions[index]),
    );
    if (!mounted || result == null) return;
    setState(() {
      if (index == null) {
        _conditions.add(result);
      } else {
        _conditions[index] = result;
      }
      _preview = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final source = _tools?.where((t) => t['name'] == _tool).firstOrNull;
    final schema = source?['inputSchema'] as Map?;
    final properties = schema?['properties'] as Map? ?? {};
    final requiredProperties = schema?['required'] as List? ?? [];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.watch == null ? 'New monitor' : 'Edit monitor'),
      ),
      body: Form(
        key: _form,
        onChanged: () {
          if (_preview != null && !_busy) setState(() => _preview = null);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Only approved read-only sources can be monitored. Nothing is monitored until you save a monitor.',
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: SelectableText(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_busy) const LinearProgressIndicator(),
            _text('title', 'Monitor name', required: true),
            _text(
              'id',
              'Stable monitor ID',
              required: true,
              enabled: widget.watch == null,
              help:
                  'Used to identify this monitor; cannot change after creation.',
            ),
            SwitchListTile(
              title: const Text('Monitoring enabled'),
              value: _enabled,
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _enabled = v;
                      _preview = null;
                    }),
            ),
            Text('Source: ${_tool.isEmpty ? 'Not selected' : _tool}'),
            OutlinedButton(
              onPressed: _busy ? null : _loadTools,
              child: const Text('Load approved sources and schemas'),
            ),
            if (_tools != null && _tools!.isEmpty)
              const Text(
                'No sources approved. Ask the server operator to approve a read-only source. No tools were executed.',
              ),
            if (_tools?.isNotEmpty == true)
              DropdownButtonFormField<String>(
                key: ValueKey('source:$_tool:${_tools!.length}'),
                initialValue: _tools!.any((t) => t['name'] == _tool)
                    ? _tool
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Approved source'),
                items: [
                  for (final t in _tools!)
                    DropdownMenuItem(
                      value: t['name'] as String,
                      child: Text('${t['name']}'),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _tool = v!;
                        _preview = null;
                      }),
              ),
            if (source != null) ...[
              Text(
                '${source['description'] ?? 'No source description provided.'}',
              ),
              const SizedBox(height: 8),
              const Text('Source inputs'),
              if (properties.isEmpty)
                const Text('This source declares no input fields.'),
              for (final entry in properties.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${entry.key}${requiredProperties.contains(entry.key) ? ' (required)' : ''}',
                  ),
                  subtitle: Text(
                    entry.value is Map
                        ? '${entry.value['type'] ?? 'value'} · ${entry.value['description'] ?? ''}'
                        : '${entry.value}',
                  ),
                ),
              ExpansionTile(
                title: const Text('Complete source schema'),
                children: [AssistantValueView(schema)],
              ),
            ],
            ExpansionTile(
              title: const Text('Source arguments (advanced JSON)'),
              initiallyExpanded: widget.watch == null,
              children: [
                const Text(
                  'Supply the named inputs described above. Preview performs a real bounded read; loading sources does not execute them.',
                ),
                _text('arguments', 'Arguments object', lines: 4),
              ],
            ),
            const Divider(),
            Text('Schedule', style: Theme.of(context).textTheme.titleLarge),
            SwitchListTile(
              title: const Text('Use cron schedule'),
              subtitle: const Text('Otherwise poll at a fixed interval'),
              value: _cron,
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _cron = v;
                      _preview = null;
                    }),
            ),
            if (_cron)
              _text(
                'cron',
                'Cron expression',
                required: true,
                help:
                    'Validated by the server; preview shows actual upcoming runs.',
              )
            else
              _text('interval', 'Check every (seconds)', number: true),
            _text(
              'timezone',
              'Schedule timezone',
              required: true,
              help: 'IANA timezone, for example America/New_York or UTC',
            ),
            const Divider(),
            Text(
              'What matters to you',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            _text(
              'interest',
              'Interests and what deserves attention',
              lines: 3,
            ),
            _text('ignore', 'Ignore (one instruction per line)', lines: 3),
            const Text('Deterministic conditions'),
            for (var i = 0; i < _conditions.length; i++)
              ListTile(
                title: Text(
                  '${_conditions[i]['id']} · ${_conditions[i]['kind']}',
                ),
                subtitle: Text(
                  '${_conditions[i]['pointer'] ?? ''} ${_conditions[i]['op'] ?? ''} ${_conditions[i]['value'] ?? ''}',
                ),
                onTap: _busy ? null : () => _condition(i),
                trailing: IconButton(
                  tooltip: 'Remove condition',
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _conditions.removeAt(i);
                          _preview = null;
                        }),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            OutlinedButton(
              onPressed: _busy ? null : () => _condition(),
              child: const Text('Add condition'),
            ),
            const Divider(),
            Text('Attention', style: Theme.of(context).textTheme.titleLarge),
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: const InputDecoration(
                labelText: 'Delivery preference',
              ),
              items: const [
                DropdownMenuItem(
                  value: 'digest',
                  child: Text('Include in digest'),
                ),
                DropdownMenuItem(
                  value: 'notify',
                  child: Text('Notify when relevant'),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _mode = v!;
                      _preview = null;
                    }),
            ),
            _text('digest', 'Digest window (seconds)', number: true),
            _text('quiet_start', 'Quiet hours start (HH:MM)'),
            _text('quiet_end', 'Quiet hours end (HH:MM)'),
            _text('attention_timezone', 'Quiet hours timezone', required: true),
            ExpansionTile(
              title: const Text('Data mapping (advanced JSON)'),
              children: [
                const Text(
                  'Optional result extraction (encoding, pointer, mode, id_pointers, compare_pointers, completeness), pagination, changes and baseline. Keep existing mapping when editing. Baseline is silent or emit; changes is a list of change types.',
                ),
                _text('mapping', 'Data mapping object', lines: 6),
              ],
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.preview_outlined),
              label: const Text('Preview source and schedule'),
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      final result = await widget.client
                          .command(widget.connection, {
                            'resource': 'observer',
                            'action': 'preview',
                            'watch': _definition(),
                          });
                      if (mounted) {
                        setState(
                          () => _preview = Map<String, dynamic>.from(
                            result['preview'] as Map,
                          ),
                        );
                      }
                    }),
            ),
            if (_preview != null) ...[
              const Text('Preview only · not saved or scheduled'),
              if (_preview!['next_runs'] is List)
                Text(
                  'Next runs: ${(_preview!['next_runs'] as List).map(assistantTime).join('\n')}',
                ),
              AssistantValueView(_preview),
            ],
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await widget.client.command(widget.connection, {
                        'resource': 'observer',
                        'action': 'save',
                        'watch': _definition(),
                        'expected_revision': widget.watch?.revision ?? 0,
                      });
                      if (context.mounted) {
                        Navigator.of(context).pop(true);
                      }
                    }),
              child: const Text('Save monitor'),
            ),
            const Text(
              'Save and delete use revision checks. Failed or offline changes are not automatically retried.',
            ),
          ],
        ),
      ),
    );
  }
}

class _ConditionDialog extends StatefulWidget {
  const _ConditionDialog({this.value});
  final AssistantJson? value;
  @override
  State<_ConditionDialog> createState() => _ConditionDialogState();
}

class _ConditionDialogState extends State<_ConditionDialog> {
  final _form = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{};
  late String _kind;
  late String _op;
  @override
  void initState() {
    super.initState();
    _kind = '${widget.value?['kind'] ?? 'threshold'}';
    _op = '${widget.value?['op'] ?? 'gt'}';
    for (final key in [
      'id',
      'pointer',
      'value',
      'window_seconds',
      'duration_seconds',
    ]) {
      _fields[key] = TextEditingController(text: '${widget.value?[key] ?? ''}');
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final numeric = ['threshold', 'sustained', 'count', 'rate'].contains(_kind);
    final window = ['count', 'rate'].contains(_kind);
    final duration = ['sustained', 'absence'].contains(_kind);
    Widget input(
      String key,
      String label, {
      bool required = false,
      bool number = false,
    }) => TextFormField(
      controller: _fields[key],
      decoration: InputDecoration(labelText: label),
      validator: (v) {
        if (required && (v == null || v.isEmpty)) return 'Required';
        if (number &&
            v != null &&
            v.isNotEmpty &&
            (num.tryParse(v) == null || !num.parse(v).isFinite)) {
          return 'Enter a finite number';
        }
        if (key.endsWith('_seconds') &&
            v != null &&
            v.isNotEmpty &&
            (int.tryParse(v) ?? 0) <= 0) {
          return 'Enter positive whole seconds';
        }
        if (key == 'pointer' &&
            v != null &&
            v.isNotEmpty &&
            !v.startsWith('/')) {
          return 'Use a JSON pointer beginning with /';
        }
        return null;
      },
    );
    return AlertDialog(
      title: const Text('Condition'),
      content: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              input('id', 'Stable condition ID', required: true),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                items: [
                  for (final k in [
                    'threshold',
                    'count',
                    'rate',
                    'sustained',
                    'absence',
                  ])
                    DropdownMenuItem(value: k, child: Text(k)),
                ],
                onChanged: (v) => setState(() => _kind = v!),
              ),
              Text(switch (_kind) {
                'threshold' => 'Compare a numeric source value.',
                'count' => 'Count material source changes within a window.',
                'rate' =>
                  'Compare the rate of material source changes within a window.',
                'sustained' =>
                  'Require a numeric comparison to remain true for a duration.',
                _ =>
                  'Detect time without material source changes after the initial baseline.',
              }),
              if (['threshold', 'sustained'].contains(_kind))
                input('pointer', 'Numeric field JSON pointer'),
              if (numeric) ...[
                DropdownButtonFormField<String>(
                  initialValue: _op,
                  items: [
                    for (final op in ['gt', 'gte', 'lt', 'lte', 'eq'])
                      DropdownMenuItem(
                        value: op,
                        child: Text(
                          {
                            'gt': 'Greater than',
                            'gte': 'At least',
                            'lt': 'Less than',
                            'lte': 'At most',
                            'eq': 'Equal to',
                          }[op]!,
                        ),
                      ),
                  ],
                  onChanged: (v) => _op = v!,
                ),
                input(
                  'value',
                  'Comparison value',
                  required: true,
                  number: true,
                ),
              ],
              if (window)
                input(
                  'window_seconds',
                  'Rolling window (seconds)',
                  required: true,
                  number: true,
                ),
              if (duration)
                input(
                  'duration_seconds',
                  'Duration (seconds)',
                  required: true,
                  number: true,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(context, <String, dynamic>{
              'id': _fields['id']!.text.trim(),
              'kind': _kind,
              if (['threshold', 'sustained'].contains(_kind))
                'pointer': _fields['pointer']!.text,
              if (numeric) ...{
                'op': _op,
                'value': num.parse(_fields['value']!.text),
              },
              if (window)
                'window_seconds': int.parse(_fields['window_seconds']!.text),
              if (duration)
                'duration_seconds': int.parse(
                  _fields['duration_seconds']!.text,
                ),
            });
          },
          child: const Text('Use condition'),
        ),
      ],
    );
  }
}
