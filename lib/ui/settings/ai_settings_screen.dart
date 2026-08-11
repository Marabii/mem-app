import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ai/ai_client.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

class AiSettingsScreen extends ConsumerStatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  ConsumerState<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends ConsumerState<AiSettingsScreen> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  final _apiKey = TextEditingController();

  bool _keyLoaded = false;
  bool _obscureKey = true;
  bool _testing = false;
  String? _testResult;
  bool _testFailed = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _baseUrl = TextEditingController(text: settings.aiBaseUrl);
    _model = TextEditingController(text: settings.aiModel);
    _loadKey();
  }

  Future<void> _loadKey() async {
    final key = await ref.read(settingsServiceProvider).readApiKey();
    if (!mounted) return;
    setState(() {
      _apiKey.text = key;
      _keyLoaded = true;
    });
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(settingsProvider.notifier).edit((s) => s.copyWith(
          aiBaseUrl: _baseUrl.text.trim(),
          aiModel: _model.text.trim(),
        ));
    await ref.read(settingsServiceProvider).writeApiKey(_apiKey.text.trim());
    ref.invalidate(apiKeyProvider);
    if (!mounted) return;
    showSnack(context, 'Saved');
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    // Test what is on screen, not what was last saved.
    final client = AiClient(
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      model: _model.text.trim(),
    );

    try {
      final models = await client.listModels();
      if (!mounted) return;
      setState(() {
        _testFailed = false;
        _testResult = models.isEmpty
            ? 'Connected to ${client.baseUrl}, but it listed no models.'
            : 'Connected. ${models.length} model(s) available:\n'
                '${models.take(8).join('\n')}';
      });
      // Save the user a step when the server names exactly one model.
      if (models.length == 1 && _model.text.trim().isEmpty) {
        setState(() => _model.text = models.first);
      }
    } on AiException catch (e) {
      if (!mounted) return;
      setState(() {
        _testFailed = true;
        _testResult = e.toString();
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI model'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'MemApp can talk to any OpenAI-compatible server — LM Studio, '
                  'Ollama, llama.cpp, or OpenAI itself — to build quizzes from '
                  'the cards you keep getting wrong. This is the only feature '
                  'that uses the network; everything else works offline.',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                ),
              ),
            ),

            const SectionHeader('Connection'),
            TextField(
              controller: _baseUrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'http://192.168.1.10:1234/v1',
                helperText: '/v1 is added automatically if you leave it off',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _model,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Model',
                hintText: 'qwen2.5-7b-instruct',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _apiKey,
              obscureText: _obscureKey,
              autocorrect: false,
              enableSuggestions: false,
              enabled: _keyLoaded,
              decoration: InputDecoration(
                labelText: 'API key',
                helperText: _keyLoaded
                    ? 'Stored in Android encrypted storage. Local servers '
                        'usually need no key.'
                    : 'Loading…',
                helperMaxLines: 3,
                suffixIcon: IconButton(
                  icon: Icon(_obscureKey
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                ),
              ),
            ),

            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          )
                        : const Icon(Icons.wifi_find_outlined),
                    label: Text(_testing ? 'Testing…' : 'Test connection'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _save,
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),

            if (_testResult != null) ...[
              const SizedBox(height: 16),
              Card(
                color: _testFailed
                    ? theme.colorScheme.errorContainer.withValues(alpha: 0.4)
                    : theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        _testFailed
                            ? Icons.error_outline
                            : Icons.check_circle_outline,
                        size: 20,
                        color: _testFailed
                            ? theme.colorScheme.error
                            : const Color(0xFF10B981),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SelectableText(
                          _testResult!,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            const SectionHeader('Generation'),
            Consumer(
              builder: (context, ref, _) {
                final settings = ref.watch(settingsProvider);
                return SettingsGroup(children: [
                  ListTile(
                    title: const Text('Temperature'),
                    subtitle: const Text(
                        'Lower is more predictable, higher is more varied'),
                    trailing: Text(settings.aiTemperature.toStringAsFixed(1),
                        style: theme.textTheme.titleMedium),
                  ),
                  Slider(
                    value: settings.aiTemperature,
                    min: 0,
                    max: 1.2,
                    divisions: 12,
                    label: settings.aiTemperature.toStringAsFixed(1),
                    onChanged: (v) => ref
                        .read(settingsProvider.notifier)
                        .edit((s) => s.copyWith(aiTemperature: v)),
                  ),
                  ListTile(
                    title: const Text('Request timeout'),
                    subtitle: const Text(
                        'Local models on modest hardware can take a while'),
                    trailing: Text('${settings.aiTimeoutSeconds}s',
                        style: theme.textTheme.titleMedium),
                  ),
                  Slider(
                    value: settings.aiTimeoutSeconds.toDouble(),
                    min: 30,
                    max: 600,
                    divisions: 19,
                    label: '${settings.aiTimeoutSeconds}s',
                    onChanged: (v) => ref
                        .read(settingsProvider.notifier)
                        .edit((s) => s.copyWith(aiTimeoutSeconds: v.round())),
                  ),
                ]);
              },
            ),
          ],
        ),
      ),
    );
  }
}
