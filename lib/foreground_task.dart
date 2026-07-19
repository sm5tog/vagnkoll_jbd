import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Callback som körs i foreground servicens isolat.
/// Vi gör inget egentligt arbete här — servicen är bara till för att hindra
/// Android från att stänga ner huvudappen i bakgrunden.
@pragma('vm:entry-point')
void startVagnkollService() {
  FlutterForegroundTask.setTaskHandler(_VagnkollTaskHandler());
}

class _VagnkollTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

class VagnkollForegroundService {
  static Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'vagnkoll_service',
        channelName: 'Vagnkoll',
        channelDescription: 'Övervakar batteri och Victron-enheter',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> start() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'Vagnkoll övervakar',
      notificationText: 'Tryck för att öppna',
      callback: startVagnkollService,
    );
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
