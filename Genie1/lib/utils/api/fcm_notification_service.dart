import 'notification_inbox.dart';
import 'lead_call_notification.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../firebase_options.dart';
import '../widget/pending_work_alarm_player.dart';

const String _leadCallChannelId = 'crm_lead_calls';

const String _pendingWorkChannelId = 'work_assignment';
const String _pendingWorkSilentChannelId = 'pending_work_alarm_playback';
const String _pendingWorkChannelMigrationKey =
    'pending_work_alarm_channel_refreshed_v1';

const AndroidNotificationChannel _pendingWorkChannel =
    AndroidNotificationChannel(
      _pendingWorkChannelId,
      'Pending Work',
      description: 'Alerts when new work is assigned to you',
      importance: Importance.high,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('work_assigned'),
      enableVibration: true,
      showBadge: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
    );

const AndroidNotificationChannel _pendingWorkSilentChannel =
    AndroidNotificationChannel(
      _pendingWorkSilentChannelId,
      'Pending Work Alerts',
      description: 'Visual alerts while the pending-work alarm is playing',
      importance: Importance.high,
      playSound: false,
      enableVibration: false,
    );

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

bool _isPendingWork(RemoteMessage message) {
  final type =
      [
            message.data['type'],
            message.data['event'],
            message.data['event_type'],
            message.data['notification_type'],
            message.data['section'],
          ]
          .where((value) => value != null && value.toString().trim().isNotEmpty)
          .join('_')
          .toUpperCase();
  final isKnownPendingType = const {
    'PENDING_WORK_ASSIGNED',
    'PENDING_WORK_CREATED',
    'WORK_ASSIGNED',
    'TASK_ASSIGNED',
    'LEAD_ASSIGNED',
    'OPPORTUNITY_ASSIGNED',
  }.contains(type);
  if (isKnownPendingType) return true;
  if (type.contains('PENDING') &&
      (type.contains('WORK') || type.contains('TASK'))) {
    return true;
  }

  final isPendingSection =
      type.contains('STOCK') ||
      type.contains('MANUFACTUR') ||
      type.contains('PROJECT');
  final indicatesNewWork =
      type.contains('PENDING') ||
      type.contains('WORK') ||
      type.contains('ASSIGNED') ||
      type.contains('CREATED');
  return isPendingSection && indicatesNewWork;
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  await NotificationInbox.capture(message);
  if (LeadCallNotification.fromData(message.data) != null) {
    if (message.notification == null) {
      await _initializeLocalNotifications();
      await showLeadCallNotification(message);
    }
    return;
  }
  if (!_isPendingWork(message) || message.notification != null) return;

  await _initializeLocalNotifications();
  await showPendingWorkNotification(message);
}

Future<void> _initializeLocalNotifications() async {
  await _localNotifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    ),
    onDidReceiveNotificationResponse: (response) {
      final payload = response.payload;
      if (payload == null) return;
      unawaited(_openLeadCallPayload(payload));
    },
  );

  final android =
      _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

  // Android keeps a channel's original sound settings after it is created.
  // Refresh this channel once so installs that had a silent version receive
  // the alarm sound configuration below.
  final preferences = await SharedPreferences.getInstance();
  if (android != null &&
      preferences.getBool(_pendingWorkChannelMigrationKey) != true) {
    await android.deleteNotificationChannel(_pendingWorkChannelId);
    await preferences.setBool(_pendingWorkChannelMigrationKey, true);
  }
  await android?.createNotificationChannel(_pendingWorkChannel);
  await android?.createNotificationChannel(_pendingWorkSilentChannel);
  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      _leadCallChannelId,
      'Lead and Opportunity Calls',
      description: 'Assigned customers awaiting a call',
      importance: Importance.high,
    ),
  );
}

class FcmNotificationService {
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await _initializeLocalNotifications();

    FirebaseMessaging.onMessage.listen((message) async {
      await NotificationInbox.capture(message);
      if (LeadCallNotification.fromData(message.data) != null) {
        await showLeadCallNotification(message);
      } else if (_isPendingWork(message)) {
        final audioUrl = message.data['alarm_audio_url']?.toString().trim();
        await showPendingWorkNotification(message, playChannelSound: false);
        await PendingWorkAlarmPlayer.play(url: audioUrl);
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) async {
      await NotificationInbox.capture(message);
      await _openRemoteLeadCall(message);
    });
    // Reading a launch notification should not delay opening the app.
    unawaited(() async {
      try {
        final initial = await FirebaseMessaging.instance
            .getInitialMessage()
            .timeout(const Duration(seconds: 5));
        if (initial != null) {
          await NotificationInbox.capture(initial);
          await _openRemoteLeadCall(initial);
        }
        final launch =
            await _localNotifications.getNotificationAppLaunchDetails();
        final payload = launch?.notificationResponse?.payload;
        if (launch?.didNotificationLaunchApp == true && payload != null) {
          await _openLeadCallPayload(payload);
        }
      } catch (error) {
        debugPrint('Could not read initial notification: ${error.runtimeType}');
      }
    }());
    _initialized = true;
    debugPrint('FCM pending-work notification listener initialized.');
  }
}

Future<void> showPendingWorkNotification(
  RemoteMessage message, {
  bool playChannelSound = true,
}) async {
  final data = message.data;
  final title =
      message.notification?.title ??
      data['title']?.toString() ??
      'New pending work';
  final body =
      message.notification?.body ??
      data['body']?.toString() ??
      'New work has been assigned to you.';

  final notificationId =
      message.messageId?.hashCode ?? DateTime.now().microsecondsSinceEpoch;

  final androidDetails = AndroidNotificationDetails(
    playChannelSound ? _pendingWorkChannelId : _pendingWorkSilentChannelId,
    'Pending Work',
    channelDescription: 'Alerts when new work is assigned to you',
    importance: Importance.high,
    priority: Priority.high,
    playSound: playChannelSound,
    sound:
        playChannelSound
            ? const RawResourceAndroidNotificationSound('work_assigned')
            : null,
    enableVibration: true,
    channelShowBadge: true,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    icon: 'ic_notification',
  );

  await _localNotifications.show(
    notificationId & 0x7fffffff,
    title,
    body,
    NotificationDetails(android: androidDetails),
    payload: jsonEncode(data),
  );

  debugPrint('Displayed pending-work alarm notification: $title');
}

Future<void> showLeadCallNotification(RemoteMessage message) async {
  final lead = LeadCallNotification.fromData(message.data);
  if (lead == null) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final user = prefs.getString('session_username');
  if (user == null || prefs.getString('session_sid') == null) return;
  final recipient = message.data['for_user'] ?? message.data['recipient'];
  if (recipient != null &&
      recipient.toString().toLowerCase() != user.toLowerCase()) {
    return;
  }
  // Stable document ID replaces repeat updates to the same assignment alert.
  final id = 'lead-call:${lead.doctype}:${lead.docname}'.hashCode & 0x7fffffff;
  await _localNotifications.show(
    id,
    lead.title,
    lead.body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        _leadCallChannelId,
        'Lead and Opportunity Calls',
        channelDescription: 'Assigned customers awaiting a call',
        importance: Importance.high,
        priority: Priority.high,
        icon: 'ic_notification',
      ),
    ),
    payload: jsonEncode({...message.data, '_genie_user': user}),
  );
}

Future<void> _openRemoteLeadCall(RemoteMessage message) async {
  final recipient = message.data['for_user'] ?? message.data['recipient'];
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final user = prefs.getString('session_username');
  if (user == null ||
      (recipient != null &&
          recipient.toString().toLowerCase() != user.toLowerCase())) {
    return;
  }
  await _openLeadCallPayload(
    jsonEncode({...message.data, '_genie_user': user}),
  );
}

Future<void> _openLeadCallPayload(String payload) async {
  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return;
    final data = Map<String, dynamic>.from(decoded);
    final lead = LeadCallNotification.fromData(data);
    if (lead == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (prefs.getString('session_sid') == null ||
        prefs.getString('session_username') != data['_genie_user']) {
      return;
    }
    // Only a notification tap opens the dialer. Push receipt never places a call.
    if (!await launchUrl(lead.dialUri, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not open the assigned customer dialer.');
    }
  } catch (error) {
    debugPrint('Could not open lead notification: ${error.runtimeType}');
  }
}
