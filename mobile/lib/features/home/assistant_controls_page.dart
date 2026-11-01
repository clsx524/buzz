import 'package:flutter/material.dart';

import '../../shared/assistant/assistant_client.dart';
import 'assistant_value_view.dart';
import 'assistant_watch_editor.dart';

class AssistantControlsPage extends StatefulWidget {
  const AssistantControlsPage({
    this.client,
    this.store,
    this.onConversation,
    super.key,
  });
  final AssistantClient? client;
  final AssistantConnectionStore? store;
  final Future<void> Function(BuildContext, String, String?)? onConversation;
  @override
  State<AssistantControlsPage> createState() => _AssistantControlsPageState();
}

class _AssistantControlsPageState extends State<AssistantControlsPage> {
  late final AssistantClient _client;
  late final AssistantConnectionStore _store;
  AssistantConnection? _connection;
  AssistantDashboard? _dashboard;
  String? _error;
  String? _notice;
  bool _busy = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? AssistantClient();
    _store = widget.store ?? AssistantConnectionStore();
    _restore();
  }

  @override
  void dispose() {
    _generation++;
    if (widget.client == null) _client.close();
    super.dispose();
  }

  Future<void> _restore() async {
    final generation = ++_generation;
    try {
      final connection = await _store.load();
      if (!mounted || generation != _generation) return;
      setState(() {
        _connection = connection;
        _busy = false;
      });
      if (connection != null) await _refresh();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = 'Could not load the secure connection: $error';
          _busy = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    final connection = _connection;
    if (connection == null) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dashboard = await _client.dashboard(connection);
      if (mounted && generation == _generation) {
        setState(() => _dashboard = dashboard);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = 'Could not refresh. Offline or server failure: $error',
        );
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _configure() async {
    final connection = await showDialog<AssistantConnection>(
      context: context,
      builder: (_) => _ConnectionDialog(
        connection: _connection,
        session: _store.sessionOnly,
      ),
    );
    if (connection == null || !mounted) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _store.save(connection);
      if (!mounted || generation != _generation) return;
      setState(() {
        _connection = connection;
        _dashboard = null;
        _notice = null;
      });
      await _refresh();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = 'Connection was not saved: $error';
          _busy = false;
        });
      }
    }
  }

  Future<void> _disconnect() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _store.clear();
      if (mounted && generation == _generation) {
        setState(() {
          _connection = null;
          _dashboard = null;
          _notice = null;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = 'Could not remove the secure connection: $error',
        );
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _command(AssistantJson command) async {
    final connection = _connection;
    if (connection == null) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _client.command(connection, command);
      if (!mounted || generation != _generation) return;
      setState(() => _notice = 'Server accepted the action.');
      await _refresh();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error =
              'Action failed or acceptance is unknown: $error. Refresh current server state before explicitly trying again. It will not be automatically retried.';
          _busy = false;
        });
      }
    }
  }

  Future<void> _edit([AssistantWatch? watch]) async {
    final connection = _connection;
    if (connection == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AssistantWatchEditor(
          client: _client,
          connection: connection,
          watch: watch,
        ),
      ),
    );
    if (mounted && saved == true && identical(connection, _connection)) {
      await _refresh();
    }
  }

  Future<void> _delete(AssistantWatch watch) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete monitor?'),
        content: Text(
          'Stop polling ${watch.definition['title']}? Factual history is retained.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _command({
        'resource': 'observer',
        'action': 'delete',
        'id': watch.id,
        'expected_revision': watch.revision,
      });
    }
  }

  Future<void> _answer(AssistantJson question) async {
    final answer = await _prompt(
      context,
      'Answer question',
      '${question['prompt']}',
    );
    if (answer != null && mounted) {
      await _command({
        'resource': 'concerns',
        'action': 'answer',
        'question_id': question['id'],
        'answer': answer,
      });
    }
  }

  Future<void> _snooze(AssistantJson concern) async {
    final seconds = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Snooze finding'),
        children: [
          for (final option in {
            3600: '1 hour',
            14400: '4 hours',
            86400: '1 day',
            604800: '1 week',
          }.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, option.key),
              child: Text(option.value),
            ),
        ],
      ),
    );
    if (seconds != null && mounted) {
      await _command({
        'resource': 'concerns',
        'action': 'snooze',
        'concern_id': concern['id'],
        'seconds': seconds,
      });
    }
  }

  Future<void> _feedback(AssistantJson decision) async {
    final feedback = await showDialog<AssistantJson>(
      context: context,
      builder: (_) => _FeedbackDialog(decision: decision),
    );
    if (feedback != null && mounted) {
      await _command({
        'resource': 'feedback',
        'action': 'submit',
        'decision_id': decision['id'],
        ...feedback,
      });
    }
  }

  Future<void> _inspect(AssistantJson concern) async {
    final connection = _connection;
    if (connection == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _EvidencePage(
          client: _client,
          connection: connection,
          concern: concern,
          onConversation: widget.onConversation,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _dashboard;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Personal assistant controls'),
        actions: [
          IconButton(
            tooltip: 'Connection settings',
            onPressed: _busy ? null : _configure,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: 'Refresh assistant',
            onPressed: _busy || _connection == null ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) ...[
            SelectableText(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            if (d != null)
              const Text(
                'Showing the last loaded snapshot. It may be out of date; actions are not queued.',
              ),
            TextButton(
              onPressed: _busy
                  ? null
                  : (_connection == null ? _restore : _refresh),
              child: const Text('Retry read'),
            ),
          ],
          if (_notice != null) Text(_notice!),
          if (_connection == null && !_busy) ...[
            const Text(
              'Connect your assistant server to manage monitors, findings and questions. Nothing is monitored until you explicitly configure a monitor.',
            ),
            FilledButton(
              onPressed: _configure,
              child: const Text('Connect assistant server'),
            ),
            if (_error != null)
              TextButton(
                onPressed: _disconnect,
                child: const Text('Remove saved connection'),
              ),
          ],
          if (_connection != null) ...[
            Text('${_connection!.origin} · Profile ${_connection!.profile}'),
            Text(
              _store.sessionOnly
                  ? 'Session-only connection. Closing the app clears the token.'
                  : 'Connection token is kept in device secure storage.',
            ),
            TextButton(
              onPressed: _busy ? null : _disconnect,
              child: const Text('Disconnect and remove token'),
            ),
          ],
          if (d != null) ...[
            ExpansionTile(
              title: const Text('Server runtime status'),
              children: [AssistantValueView(d.runtime)],
            ),
            Text('Monitors', style: Theme.of(context).textTheme.headlineSmall),
            if (d.watches.isEmpty)
              const Text(
                'Nothing is monitored until you configure a monitor. No sources have been called by this screen.',
              ),
            for (final watch in d.watches)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${watch.definition['title']}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '${watch.id} · ${watch.definition['tool']} · ${watch.definition['enabled'] == true ? 'Enabled' : 'Paused'} · revision ${watch.revision}',
                      ),
                      Text(
                        watch.definition['cron'] != null
                            ? 'Cron ${watch.definition['cron']} · ${watch.definition['timezone'] ?? 'UTC'}'
                            : 'Every ${watch.definition['interval_seconds']} seconds',
                      ),
                      Text(
                        'Next runs: ${(watch.json['next_runs'] as List? ?? []).map(assistantTime).join(', ')}',
                      ),
                      ExpansionTile(
                        title: const Text(
                          'Last check, errors and runtime details',
                        ),
                        children: [
                          AssistantValueView({
                            for (final e in watch.json.entries)
                              if (e.key != 'definition') e.key: e.value,
                          }),
                        ],
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: _busy ? null : () => _edit(watch),
                            child: const Text('Edit'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () {
                                    final changed = AssistantWatch({
                                      ...watch.json,
                                      'definition': {
                                        ...watch.definition,
                                        'enabled':
                                            watch.definition['enabled'] != true,
                                      },
                                    });
                                    _command({
                                      'resource': 'observer',
                                      'action': 'save',
                                      'watch': changed.definition,
                                      'expected_revision': watch.revision,
                                    });
                                  },
                            child: Text(
                              watch.definition['enabled'] == true
                                  ? 'Pause monitor'
                                  : 'Enable monitor',
                            ),
                          ),
                          TextButton(
                            onPressed: _busy ? null : () => _delete(watch),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            FilledButton.icon(
              onPressed: _busy ? null : () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('Add monitor'),
            ),
            const Divider(),
            Text('Findings', style: Theme.of(context).textTheme.headlineSmall),
            if (d.concerns.isEmpty)
              const Text('No findings returned by the server.'),
            for (final concern in d.concerns)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${concern['title']}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text('${concern['summary'] ?? ''}'),
                      Text('${concern['status']} · ${concern['id']}'),
                      if (concern['watch_id'] != null)
                        Text(
                          'Monitor ${concern['watch_id']} · Record ${concern['record_id'] ?? 'not provided'}',
                        ),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: _busy ? null : () => _inspect(concern),
                            child: const Text('Evidence and history'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _command({
                                    'resource': 'concerns',
                                    'action': 'handled',
                                    'concern_id': concern['id'],
                                  }),
                            child: const Text('Mark handled'),
                          ),
                          TextButton(
                            onPressed: _busy ? null : () => _snooze(concern),
                            child: const Text('Snooze'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _command({
                                    'resource': 'concerns',
                                    'action': 'resume',
                                    'concern_id': concern['id'],
                                  }),
                            child: const Text('Resume'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            const Divider(),
            Text('Questions', style: Theme.of(context).textTheme.headlineSmall),
            if (d.questions.isEmpty)
              const Text('No questions returned by the server.'),
            for (final q in d.questions)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${q['prompt']}'),
                subtitle: Text(
                  'Finding ${q['concern_id']} · ${q['answer'] == null ? 'Awaiting your answer' : 'Answer: ${q['answer']}'}',
                ),
                trailing: q['answer'] == null
                    ? TextButton(
                        onPressed: _busy ? null : () => _answer(q),
                        child: const Text('Answer'),
                      )
                    : null,
              ),
            const Divider(),
            Text('Decisions', style: Theme.of(context).textTheme.headlineSmall),
            if (d.decisions.isEmpty)
              const Text('No decisions returned by the server.'),
            for (final decision in d.decisions)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${decision['title']}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '${decision['kind']} · ${assistantTime(decision['created'])} · Finding ${decision['concern_id']}',
                      ),
                      Text('${decision['summary'] ?? ''}'),
                      Text('${decision['rationale'] ?? ''}'),
                      ExpansionTile(
                        title: const Text('Decision context and evidence'),
                        children: [AssistantValueView(decision)],
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _feedback(decision),
                        child: const Text('Feedback and preference'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({required this.connection, required this.session});
  final AssistantConnection? connection;
  final bool session;
  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  late final TextEditingController _origin;
  late final TextEditingController _profile;
  late final TextEditingController _token;
  String? _error;
  @override
  void initState() {
    super.initState();
    _origin = TextEditingController(text: widget.connection?.origin ?? '');
    _profile = TextEditingController(text: widget.connection?.profile ?? '');
    _token = TextEditingController(text: widget.connection?.token ?? '');
  }

  @override
  void dispose() {
    _origin.dispose();
    _profile.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Assistant server connection'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Use the dedicated personal assistant client API token, not an observer token or relay credential. Use HTTPS outside trusted local development.',
          ),
          Text(
            widget.session
                ? 'Web token stays in memory for this session only.'
                : 'Saved together as one device-only secure snapshot.',
          ),
          TextField(
            controller: _origin,
            decoration: const InputDecoration(
              labelText: 'Server origin',
              hintText: 'https://assistant.example',
            ),
          ),
          TextField(
            controller: _profile,
            decoration: const InputDecoration(labelText: 'Hermes profile'),
          ),
          TextField(
            controller: _token,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Client API token'),
          ),
          if (_error != null) Text(_error!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          try {
            Navigator.pop(
              context,
              AssistantConnection(
                origin: _origin.text,
                profile: _profile.text,
                token: _token.text,
              ),
            );
          } catch (error) {
            setState(() => _error = '$error');
          }
        },
        child: const Text('Save connection'),
      ),
    ],
  );
}

Future<String?> _prompt(BuildContext context, String title, String message) =>
    showDialog<String>(
      context: context,
      builder: (_) => _AnswerDialog(title: title, message: message),
    );

class _AnswerDialog extends StatefulWidget {
  const _AnswerDialog({required this.title, required this.message});
  final String title;
  final String message;
  @override
  State<_AnswerDialog> createState() => _AnswerDialogState();
}

class _AnswerDialogState extends State<_AnswerDialog> {
  final _controller = TextEditingController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.message),
          TextField(
            controller: _controller,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(labelText: 'Your answer'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_controller.text.trim().isNotEmpty) {
            Navigator.pop(context, _controller.text.trim());
          }
        },
        child: const Text('Send answer'),
      ),
    ],
  );
}

class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog({required this.decision});
  final AssistantJson decision;
  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  String _signal = 'useful';
  final _comment = TextEditingController();
  final _preference = TextEditingController();
  @override
  void dispose() {
    _comment.dispose();
    _preference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Feedback: ${widget.decision['title']}'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _signal,
            isExpanded: true,
            items: [
              for (final e in {
                'useful': 'Useful',
                'irrelevant': 'Irrelevant',
                'digest': 'Prefer a digest',
                'already_handled': 'Already handled',
                'incorrect': 'Incorrect',
                'missed': 'Missed something',
              }.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => _signal = v!,
          ),
          TextField(
            controller: _comment,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Comment (optional)'),
          ),
          TextField(
            controller: _preference,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Explicit preference (optional)',
              helperText: 'Saved in assistant memory and applied immediately.',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, <String, dynamic>{
          'signal': _signal,
          if (_comment.text.trim().isNotEmpty) 'comment': _comment.text.trim(),
          if (_preference.text.trim().isNotEmpty)
            'preference': _preference.text.trim(),
        }),
        child: const Text('Submit feedback'),
      ),
    ],
  );
}

class _EvidencePage extends StatefulWidget {
  const _EvidencePage({
    required this.client,
    required this.connection,
    required this.concern,
    this.onConversation,
  });
  final AssistantClient client;
  final AssistantConnection connection;
  final AssistantJson concern;
  final Future<void> Function(BuildContext, String, String?)? onConversation;
  @override
  State<_EvidencePage> createState() => _EvidencePageState();
}

class _EvidencePageState extends State<_EvidencePage> {
  AssistantJson? _evidence;
  String? _error;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await widget.client.command(widget.connection, {
        'resource': 'concerns',
        'action': 'inspect',
        'concern_id': widget.concern['id'],
      });
      if (mounted) setState(() => _evidence = value);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('${widget.concern['title']}')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) ...[
          Text('Evidence unavailable: $_error'),
          TextButton(
            onPressed: _loading ? null : _load,
            child: const Text('Retry evidence read'),
          ),
        ],
        if (_evidence != null && widget.onConversation != null)
          for (final link in [
            ...(_evidence!['conversation_links'] as List? ?? []),
            ...(_evidence!['delivery_links'] as List? ?? []),
          ])
            if (link is Map &&
                link['channel_id'] is String &&
                (link['channel_id'] as String).isNotEmpty)
              TextButton(
                onPressed: () => widget.onConversation!(
                  context,
                  link['channel_id'] as String,
                  link['root'] as String?,
                ),
                child: const Text('Open linked conversation'),
              ),
        AssistantValueView(_evidence ?? widget.concern),
        const Text(
          'Conversations and signed reports remain available from Today and Library. Only explicit server-provided links are shown in evidence; no conversation IDs are inferred.',
        ),
      ],
    ),
  );
}
