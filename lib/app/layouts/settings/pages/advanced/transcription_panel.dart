import 'package:animated_size_and_fade/animated_size_and_fade.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Settings panel for the OpenAI audio-transcription feature.
/// See [TranscriptionService] for the runtime behavior.
class TranscriptionPanel extends StatefulWidget {
  const TranscriptionPanel({super.key});

  @override
  State<StatefulWidget> createState() => _TranscriptionPanelState();
}

class _TranscriptionPanelState extends State<TranscriptionPanel> with ThemeHelpers {
  /// Known OpenAI transcription models, cheapest first.
  static const List<String> _models = ["whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe"];

  Future<void> _editText({
    required String title,
    required String label,
    required String settingKey,
    required RxString value,
    bool obscure = false,
  }) async {
    final controller = TextEditingController(text: value.value);
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title, style: context.theme.textTheme.titleLarge),
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: obscure,
          enableSuggestions: !obscure,
          autocorrect: !obscure,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            child: Text("Cancel",
                style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
          ),
          TextButton(
            onPressed: () async {
              value.value = controller.text;
              await SettingsSvc.settings.saveOneAsync(settingKey);
              if (mounted) Navigator.of(context, rootNavigator: true).pop();
            },
            child: Text("OK",
                style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickModel() async {
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text("Transcription Model", style: context.theme.textTheme.titleLarge),
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _models
              .map((m) => Obx(() => ListTile(
                    title: Text(m, style: context.theme.textTheme.bodyLarge),
                    trailing: SettingsSvc.settings.transcriptionModel.value == m
                        ? Icon(Icons.check, color: context.theme.colorScheme.primary)
                        : null,
                    onTap: () async {
                      SettingsSvc.settings.transcriptionModel.value = m;
                      await SettingsSvc.settings.saveOneAsync('transcriptionModel');
                      if (mounted) Navigator.of(context, rootNavigator: true).pop();
                    },
                  )))
              .toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: "Audio Transcription",
      initialHeader: "Audio Transcription",
      iosSubtitle: iosSubtitle,
      materialSubtitle: materialSubtitle,
      tileColor: tileColor,
      headerColor: headerColor,
      bodySlivers: [
        SliverList(
          delegate: SliverChildListDelegate(
            <Widget>[
              SettingsSection(
                backgroundColor: tileColor,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0, left: 15, top: 8.0, right: 15),
                    child: RichText(
                      text: TextSpan(
                        style: context.theme.textTheme.bodyMedium,
                        children: const [
                          TextSpan(
                            text: "Automatically transcribes incoming audio voice memos using OpenAI's "
                                "transcription API, then replies into the chat with the text.\n\n",
                          ),
                          TextSpan(
                            text: "Heads up: the transcription is sent as a real reply, so the other "
                                "person receives it too. Audio is uploaded to OpenAI for processing and "
                                "billed to your API key.",
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Obx(
                    () => SettingsSwitch(
                      onChanged: (bool val) async {
                        SettingsSvc.settings.enableAudioTranscription.value = val;
                        await SettingsSvc.settings.saveOneAsync('enableAudioTranscription');
                      },
                      initialVal: SettingsSvc.settings.enableAudioTranscription.value,
                      title: "Enable Audio Transcription",
                      subtitle: "Transcribe incoming voice memos and reply with the text",
                      backgroundColor: tileColor,
                      leading: const SettingsLeadingIcon(
                        iosIcon: CupertinoIcons.waveform,
                        materialIcon: Icons.graphic_eq,
                        containerColor: Colors.indigo,
                      ),
                    ),
                  ),
                ],
              ),
              Obx(
                () => AnimatedSizeAndFade.showHide(
                  show: SettingsSvc.settings.enableAudioTranscription.value,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SettingsHeader(
                        iosSubtitle: iosSubtitle,
                        materialSubtitle: materialSubtitle,
                        text: "OpenAI",
                      ),
                      SettingsSection(
                        backgroundColor: tileColor,
                        children: [
                          Obx(
                            () => SettingsTile(
                              backgroundColor: tileColor,
                              title: "OpenAI API Key",
                              subtitle: SettingsSvc.settings.transcriptionApiKey.value.isEmpty
                                  ? "Not set — tap to add your key"
                                  : "Set (tap to change)",
                              onTap: () => _editText(
                                title: "OpenAI API Key",
                                label: "sk-...",
                                settingKey: "transcriptionApiKey",
                                value: SettingsSvc.settings.transcriptionApiKey,
                                obscure: true,
                              ),
                              leading: const SettingsLeadingIcon(
                                iosIcon: CupertinoIcons.lock_fill,
                                materialIcon: Icons.key,
                                containerColor: Colors.blueGrey,
                              ),
                            ),
                          ),
                          const SettingsDivider(),
                          Obx(
                            () => SettingsTile(
                              backgroundColor: tileColor,
                              title: "Model",
                              subtitle: SettingsSvc.settings.transcriptionModel.value,
                              onTap: _pickModel,
                              leading: const SettingsLeadingIcon(
                                iosIcon: CupertinoIcons.cube_box,
                                materialIcon: Icons.model_training,
                                containerColor: Colors.teal,
                              ),
                            ),
                          ),
                          const SettingsDivider(),
                          Obx(
                            () => SettingsTile(
                              backgroundColor: tileColor,
                              title: "Reply Prefix",
                              subtitle: SettingsSvc.settings.transcriptionPrefix.value.isEmpty
                                  ? "None"
                                  : "\"${SettingsSvc.settings.transcriptionPrefix.value}\"",
                              onTap: () => _editText(
                                title: "Reply Prefix",
                                label: "Text shown before each transcription",
                                settingKey: "transcriptionPrefix",
                                value: SettingsSvc.settings.transcriptionPrefix,
                              ),
                              leading: const SettingsLeadingIcon(
                                iosIcon: CupertinoIcons.textformat,
                                materialIcon: Icons.short_text,
                                containerColor: Colors.deepPurple,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
