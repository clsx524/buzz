import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'default_agent.dart';
import 'me_assistants.dart';

/// A stored explicit selection wins. Only the existing owned server inventory is
/// considered; choosing this default never starts an agent on the phone.
final personalAssistantProvider = Provider<String?>((ref) {
  final preference = ref.watch(defaultAgentProvider);
  final inventory = ref.watch(meAssistantsProvider);
  if (preference.isLoading ||
      preference.hasError ||
      inventory.isLoading ||
      inventory.hasError) {
    return null;
  }
  final choices = inventory.value ?? [];
  if (preference.value != null) {
    return choices.any((entry) => entry.pubkey == preference.value)
        ? preference.value
        : null;
  }
  final hermes = choices
      .where(
        (entry) => (entry.displayName ?? '').toLowerCase().contains('hermes'),
      )
      .firstOrNull;
  return hermes?.pubkey ?? choices.firstOrNull?.pubkey;
});
