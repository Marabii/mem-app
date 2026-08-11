import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../widgets/common.dart';

class ServerScreen extends ConsumerWidget {
  const ServerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final service = ref.watch(webServerServiceProvider);
    final state = ref.watch(webServerStateProvider).valueOrNull ?? service.state;
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Web server')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: state.running
                                ? const Color(0xFF10B981)
                                : theme.colorScheme.outline,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          state.running ? 'Running' : 'Stopped',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        if (state.running)
                          Text(
                            '${state.requestCount} requests',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (state.running && state.url != null) ...[
                      Text('Open this on any device on the same Wi-Fi:',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () => _copy(context, state.url!),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 14),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: SelectableText(
                                  state.url!,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Icon(Icons.copy,
                                  size: 18,
                                  color: theme.colorScheme.onSurfaceVariant),
                            ],
                          ),
                        ),
                      ),
                      if (state.url!.contains('localhost')) ...[
                        const SizedBox(height: 10),
                        Text(
                          'No Wi-Fi address found. Connect this phone to a '
                          'Wi-Fi network for other devices to reach it.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error),
                        ),
                      ],
                    ] else if (state.error != null) ...[
                      Text(state.error!,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.error)),
                    ] else
                      Text(
                        'Start the server to add and edit cards from a browser '
                        'on your laptop. Changes appear here immediately.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: state.running
                          ? OutlinedButton.icon(
                              onPressed: () => _stop(ref),
                              icon: const Icon(Icons.stop_rounded),
                              label: const Text('Stop server'),
                            )
                          : FilledButton.icon(
                              onPressed: state.starting
                                  ? null
                                  : () => _start(ref, settings.serverPort),
                              icon: state.starting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2.2),
                                    )
                                  : const Icon(Icons.play_arrow_rounded),
                              label: Text(state.starting
                                  ? 'Starting…'
                                  : 'Start server'),
                            ),
                    ),
                  ],
                ),
              ),
            ),

            const SectionHeader('Configuration'),
            SettingsGroup(children: [
              ListTile(
                leading: const Icon(Icons.numbers),
                title: const Text('Port'),
                subtitle: Text(state.running
                    ? 'In use: ${state.port}'
                    : 'Stop the server to change this'),
                trailing: Text('${settings.serverPort}',
                    style: theme.textTheme.titleMedium),
                enabled: !state.running,
                onTap: state.running ? null : () => _editPort(context, ref),
              ),
            ]),

            const SectionHeader('Before you share the link'),
            Card(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_open,
                        color: theme.colorScheme.error, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'The server has no password. While it is running, anyone '
                        'on this Wi-Fi network who reaches the address above can '
                        'read, edit and delete all of your cards. Leave it off on '
                        'networks you do not control, and stop it when you are done.',
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Android may suspend the app after a while in the background, '
                'which stops the server. Keep MemApp open on screen while you '
                'are editing from a browser.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _start(WidgetRef ref, int port) async {
    final service = ref.read(webServerServiceProvider);
    final state = await service.start(preferredPort: port);
    if (state.running && state.url != null) {
      await ref.read(notificationServiceProvider).showServerRunning(state.url!);
    }
  }

  Future<void> _stop(WidgetRef ref) async {
    await ref.read(webServerServiceProvider).stop();
    await ref.read(notificationServiceProvider).hideServerRunning();
  }

  void _copy(BuildContext context, String url) {
    Clipboard.setData(ClipboardData(text: url));
    showSnack(context, 'Address copied');
  }

  Future<void> _editPort(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(
        text: '${ref.read(settingsProvider).serverPort}');

    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Server port'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '8080',
            helperText: 'Between 1024 and 65535',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (value == null) return;
    if (value < 1024 || value > 65535) {
      if (context.mounted) {
        showSnack(context, 'Pick a port between 1024 and 65535', isError: true);
      }
      return;
    }
    await ref
        .read(settingsProvider.notifier)
        .edit((s) => s.copyWith(serverPort: value));
  }
}
