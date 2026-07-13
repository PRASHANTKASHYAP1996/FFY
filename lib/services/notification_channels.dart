import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const String friendifyChatMessagesChannelId = 'chat_messages';
const String friendifyChatMessagesChannelName = 'Chat messages';
const String friendifyChatMessagesChannelDescription =
    'Notifications for new messages in Friendify chats.';
const String friendifyIncomingCallsChannelId = 'incoming_calls';
const String friendifyIncomingCallsChannelName = 'Incoming calls';
const String friendifyIncomingCallsChannelDescription =
    'Urgent incoming Friendify voice call alerts.';
const String friendifyCallkitIncomingChannelId = 'callkit_incoming_channel_id';
const String friendifyCallkitIncomingChannelName = 'Incoming Call';
const String friendifyCallkitIncomingChannelDescription =
    'Incoming CallKit-style Friendify call alerts.';
const String friendifyMissedCallsChannelId = 'missed_calls';
const String friendifyMissedCallsChannelName = 'Missed calls';
const String friendifyMissedCallsChannelDescription =
    'Missed Friendify voice call alerts.';
const String friendifyOngoingCallsChannelId = 'ongoing_calls';
const String friendifyOngoingCallsChannelName = 'Ongoing calls';
const String friendifyOngoingCallsChannelDescription =
    'Persistent status while a Friendify voice call is active.';

const AndroidNotificationChannel friendifyChatMessagesChannel =
    AndroidNotificationChannel(
  friendifyChatMessagesChannelId,
  friendifyChatMessagesChannelName,
  description: friendifyChatMessagesChannelDescription,
  importance: Importance.defaultImportance,
);

final AndroidNotificationChannel friendifyIncomingCallsChannel =
    AndroidNotificationChannel(
  friendifyIncomingCallsChannelId,
  friendifyIncomingCallsChannelName,
  description: friendifyIncomingCallsChannelDescription,
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  vibrationPattern: Int64List.fromList(<int>[0, 450, 250, 450, 250, 700]),
);

final AndroidNotificationChannel friendifyCallkitIncomingChannel =
    AndroidNotificationChannel(
  friendifyCallkitIncomingChannelId,
  friendifyCallkitIncomingChannelName,
  description: friendifyCallkitIncomingChannelDescription,
  importance: Importance.max,
  playSound: false,
  enableVibration: true,
  vibrationPattern: Int64List.fromList(<int>[0, 450, 250, 450, 250, 700]),
);

final AndroidNotificationChannel friendifyMissedCallsChannel =
    AndroidNotificationChannel(
  friendifyMissedCallsChannelId,
  friendifyMissedCallsChannelName,
  description: friendifyMissedCallsChannelDescription,
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
  vibrationPattern: Int64List.fromList(<int>[0, 220, 160, 220]),
);

const AndroidNotificationChannel friendifyOngoingCallsChannel =
    AndroidNotificationChannel(
  friendifyOngoingCallsChannelId,
  friendifyOngoingCallsChannelName,
  description: friendifyOngoingCallsChannelDescription,
  importance: Importance.low,
  playSound: false,
  enableVibration: false,
);

bool _notificationChannelsInitialized = false;

Future<void> ensureFriendifyNotificationChannelsInitialized() async {
  if (_notificationChannelsInitialized) return;
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    _notificationChannelsInitialized = true;
    return;
  }

  try {
    debugPrint('notification_channels.ensure_begin');
    final plugin = FlutterLocalNotificationsPlugin();
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    await android?.createNotificationChannel(friendifyIncomingCallsChannel);
    await android?.createNotificationChannel(friendifyCallkitIncomingChannel);
    await android?.createNotificationChannel(friendifyMissedCallsChannel);
    await android?.createNotificationChannel(friendifyOngoingCallsChannel);
    await android?.createNotificationChannel(friendifyChatMessagesChannel);
    _notificationChannelsInitialized = true;
    debugPrint('notification_channels.ensure_success');
  } catch (e) {
    debugPrint(
      'Failed to create Android notification channels: ${e.runtimeType}',
    );
  }
}
