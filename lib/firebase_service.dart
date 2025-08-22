import 'dart:convert';
import 'dart:io';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:hive/hive.dart';
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'chat_message_model.dart';

class FirebaseService {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final FirebaseStorage _storage = FirebaseStorage.instance;
  Box? _hiveBox;

  // Path to your service account JSON file (for server-side; mobile apps usually shouldn't ship this)
  static const String _serviceAccountPath = 'assets/service-account.json';

  // Initialize Hive box for chat messages
  Future<void> initHive(String chatId) async {
    try {
      final boxName = 'chat_$chatId';
      if (!Hive.isBoxOpen(boxName)) {
        _hiveBox = await Hive.openBox(boxName);
        print('Hive box initialized: $boxName');
      } else {
        _hiveBox = Hive.box(boxName);
      }
    } catch (e) {
      print('Error initializing Hive box: $e');
      rethrow;
    }
  }

  // Cache messages to Hive
  Future<void> cacheMessages(String chatId, List<ChatMessage> messages) async {
    try {
      final data = messages.map((msg) => msg.toMap()).toList();
      await _hiveBox?.put('messages', data);
      print(
          'Messages cached to Hive for chatId: $chatId, count: ${data.length}');
    } catch (e) {
      print('Error caching messages to Hive: $e');
      // don't rethrow to avoid UI crashes
    }
  }

  // Load cached messages from Hive
  List<ChatMessage> loadCachedMessages() {
    try {
      final data = _hiveBox?.get('messages', defaultValue: []);
      if (data is List) {
        final messages = data
            .map((e) => ChatMessage.fromMap(Map<String, dynamic>.from(e)))
            .toList();
        print('Retrieved ${messages.length} messages from Hive');
        return messages;
      }
      print('No messages found in Hive');
      return [];
    } catch (e) {
      print('Error loading cached messages: $e');
      return [];
    }
  }

  // Send notification using FCM HTTP v1 API (skips if token empty or service account missing)
  Future<void> sendPushNotification({
    required String fcmToken,
    required String title,
    required String body,
  }) async {
    try {
      if (fcmToken.isEmpty) {
        print('No FCM token provided — skipping push notification');
        return;
      }

      if (!File(_serviceAccountPath).existsSync()) {
        print(
            'Service account file not found at $_serviceAccountPath — skipping push notification');
        return;
      }

      final serviceAccount =
          jsonDecode(await File(_serviceAccountPath).readAsString());
      final credentials =
          auth.ServiceAccountCredentials.fromJson(serviceAccount);
      final scopes = ['https://www.googleapis.com/auth/firebase.messaging'];
      final client = await auth.clientViaServiceAccount(credentials, scopes);

      final response = await client.post(
        Uri.parse(
            'https://fcm.googleapis.com/v1/projects/${serviceAccount['project_id']}/messages:send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'message': {
            'token': fcmToken,
            'notification': {
              'title': title,
              'body': body,
            },
            'android': {'priority': 'high'},
            'apns': {
              'payload': {
                'aps': {'contentAvailable': true},
              },
            },
          },
        }),
      );

      if (response.statusCode == 200) {
        print('Push notification sent successfully: ${response.body}');
      } else {
        print(
            'Failed to send push notification: ${response.statusCode} - ${response.body}');
      }

      client.close();
    } catch (e) {
      print('Error sending push notification: $e');
    }
  }

  // Get FCM token for current device
  Future<String?> getDeviceToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      print('Retrieved FCM token: $token');
      return token;
    } catch (e) {
      print('Error getting FCM token: $e');
      return null;
    }
  }

  // Send text message
  Future<void> sendText({
    required String chatId,
    required String senderId,
    required String receiverId,
    required String receiverFcmToken,
    required String text,
    required String messageId,
  }) async {
    try {
      await initHive(chatId);

      final message = ChatMessage(
        id: messageId,
        chatId: chatId,
        senderId: senderId,
        receiverId: receiverId,
        text: text,
        timestamp: DateTime.now(),
        status: 'sent',
        seen: false,
      );

      await _db.child('chats/$chatId/messages/$messageId').set(message.toMap());
      print('Text message sent to Realtime Database: $messageId');

      // optimistic: mark delivered after DB write
      await _updateToDelivered(chatId, messageId);

      final currentMessages = loadCachedMessages();
      currentMessages.removeWhere((m) => m.id == messageId);
      currentMessages.add(message);
      await cacheMessages(chatId, currentMessages);

      // Push notification only if token available
      await sendPushNotification(
        fcmToken: receiverFcmToken,
        title: "New Message",
        body: text,
      );
    } catch (e) {
      print('Detailed error sending text message: $e');
      rethrow;
    }
  }

  // Upload image and send message
  Future<String> sendImage({
    required String chatId,
    required String senderId,
    required String receiverId,
    required String receiverFcmToken,
    required File imageFile,
    required String messageId,
  }) async {
    try {
      await initHive(chatId);

      final imageUrl = await uploadImage(imageFile);

      final message = ChatMessage(
        id: messageId,
        chatId: chatId,
        senderId: senderId,
        receiverId: receiverId,
        imageUrl: imageUrl,
        timestamp: DateTime.now(),
        status: 'sent',
        seen: false,
      );

      await _db.child('chats/$chatId/messages/$messageId').set(message.toMap());
      print('Image message sent to Realtime Database: $messageId');

      await _updateToDelivered(chatId, messageId);

      final currentMessages = loadCachedMessages();
      currentMessages.removeWhere((m) => m.id == messageId);
      currentMessages.add(message);
      await cacheMessages(chatId, currentMessages);

      await sendPushNotification(
        fcmToken: receiverFcmToken,
        title: "New Image",
        body: "📷 You received an image",
      );

      return imageUrl;
    } catch (e) {
      print('Detailed error sending image message: $e');
      rethrow;
    }
  }

  // Image upload with error handling
  Future<String> uploadImage(File imageFile) async {
    try {
      if (!imageFile.existsSync()) {
        throw Exception('Image file does not exist: ${imageFile.path}');
      }
      final fileName =
          'chat_images/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final ref = _storage.ref().child(fileName);
      final uploadTask = ref.putFile(imageFile);
      final snapshot = await uploadTask
          .whenComplete(() => print('Image upload completed for $fileName'));
      final url = await snapshot.ref.getDownloadURL();
      print('Image uploaded successfully: $url');
      return url;
    } catch (e) {
      print('Error uploading image: $e');
      if (e is FirebaseException) {
        print('Firebase error details: ${e.code} - ${e.message}');
      }
      rethrow;
    }
  }

  // Update message status to 'delivered'
  Future<void> _updateToDelivered(String chatId, String messageId) async {
    try {
      await _db.child('chats/$chatId/messages/$messageId').update({
        'status': 'delivered',
      });
      print('Message status updated to delivered: $messageId');
    } catch (e) {
      print('Error updating message status to delivered: $e');
    }
  }

  // Stream messages from Realtime Database
  Stream<List<ChatMessage>> messagesStream(String chatId) {
    return _db.child('chats/$chatId/messages').onValue.asyncMap((event) async {
      try {
        await initHive(chatId);
        final value = event.snapshot.value;
        if (value == null) {
          print('No messages found in Realtime Database for chatId: $chatId');
          return loadCachedMessages();
        }

        if (value is! Map) {
          print('Unexpected messages type: ${value.runtimeType}');
          return loadCachedMessages();
        }

        final messagesMap = Map<dynamic, dynamic>.from(value);
        final messages = messagesMap.entries
            .map((e) =>
                ChatMessage.fromMap(Map<String, dynamic>.from(e.value as Map)))
            .toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

        await cacheMessages(chatId, messages);
        print('Streamed ${messages.length} messages from Realtime Database');
        return messages;
      } catch (e) {
        print('Error streaming messages: $e');
        return loadCachedMessages();
      }
    });
  }

  // Mark message as seen
  Future<void> markMessageAsSeen(String chatId, String messageId) async {
    try {
      await _db.child('chats/$chatId/messages/$messageId').update({
        'seen': true,
        'status': 'seen',
      });
      print('Message marked as seen: $messageId');
    } catch (e) {
      print('Error marking message as seen: $e');
    }
  }
}
