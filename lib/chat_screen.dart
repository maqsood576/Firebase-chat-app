import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

class ChatScreen extends StatefulWidget {
  final String chatId;
  final String senderId;
  final String receiverId;
  final String receiverName;
  final String receiverPhoto;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.senderId,
    required this.receiverId,
    required this.receiverName,
    required this.receiverPhoto,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isFirebaseInitialized = false;

  @override
  void initState() {
    super.initState();
    _ensureFirebaseInitialized();
  }

  Future<void> _ensureFirebaseInitialized() async {
    try {
      if (!Firebase.apps.isEmpty) {
        _isFirebaseInitialized = true;
        debugPrint('✅ Firebase already initialized');
        return;
      }
      await Firebase.initializeApp();
      _isFirebaseInitialized = true;
      debugPrint('✅ Firebase initialized in ChatScreen');
    } catch (e) {
      debugPrint('❌ Firebase initialization failed in ChatScreen: $e');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<bool> _requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt >= 33) {
      final status = await Permission.photos.request();
      if (!status.isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo permission denied')),
        );
        debugPrint('🛑 Photo permission denied for API 33+');
        return false;
      }
      debugPrint('✅ Photo permission granted for API 33+');
      return true;
    } else {
      final status = await Permission.storage.request();
      if (!status.isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Storage permission denied')),
        );
        debugPrint('🛑 Storage permission denied for API < 33');
        return false;
      }
      debugPrint('✅ Storage permission granted for API < 33');
      return true;
    }
  }

  Future<String?> _uploadImage(XFile image) async {
    try {
      final ref = FirebaseStorage.instance.ref().child(
            'chat_images/${widget.chatId}/${const Uuid().v4()}.jpg',
          );
      final uploadTask = await ref.putFile(File(image.path));
      final imageUrl = await uploadTask.ref.getDownloadURL();
      debugPrint('📤 Image uploaded: $imageUrl');
      return imageUrl;
    } catch (e) {
      debugPrint('❌ Error uploading image: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to upload image: $e')),
      );
      return null;
    }
  }

  Future<void> _sendMessage({XFile? image}) async {
    if (_controller.text.trim().isEmpty && image == null) {
      debugPrint('🛑 Empty message or no image provided');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot send empty message')),
      );
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint('🛑 No authenticated user');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No authenticated user')),
      );
      return;
    }

    if (widget.senderId != user.uid) {
      debugPrint(
        '🛑 Sender ID mismatch: widget.senderId=${widget.senderId}, user.uid=${user.uid}',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sender ID mismatch')),
      );
      return;
    }

    if (!_isFirebaseInitialized) {
      debugPrint('🛑 Firebase not initialized');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification service unavailable')),
      );
      return;
    }

    final messageId = const Uuid().v4();
    String? imageUrl;
    if (image != null) {
      if (await _requestStoragePermission()) {
        imageUrl = await _uploadImage(image);
        if (imageUrl == null) {
          debugPrint('🛑 Image upload failed, aborting message send');
          return;
        }
      } else {
        debugPrint('🛑 Permission denied, aborting message send');
        return;
      }
    }

    final messageData = {
      'senderId': widget.senderId,
      'receiverId': widget.receiverId,
      'message': _controller.text.trim(),
      'timestamp': FieldValue.serverTimestamp(),
      'imageUrl': imageUrl ?? '',
    };

    debugPrint(
      '📩 Sending message: chatId=${widget.chatId}, senderId=${widget.senderId}, messageData=$messageData',
    );

    try {
      await FirebaseFirestore.instance
          .collection('messages')
          .doc(widget.chatId)
          .collection('chat')
          .doc(messageId)
          .set(messageData);

      _controller.clear();
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );

      final receiverToken = await _getReceiverFcmToken();
      if (receiverToken != null) {
        await _sendPushNotification(
          receiverToken,
          widget.receiverName,
          imageUrl != null ? 'Image sent' : _controller.text.trim(),
        );
      }
    } catch (e) {
      debugPrint('❌ Error sending message: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send message: $e')),
      );
    }
  }

  Future<String?> _getReceiverFcmToken() async {
    if (widget.senderId == widget.receiverId) {
      debugPrint('🛑 Skipping notification: Sender and receiver are the same');
      return null;
    }

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.receiverId)
          .get();
      if (snapshot.exists) {
        final token = snapshot.data()?['fcmToken'] as String?;
        debugPrint('🔍 Receiver FCM token: $token');
        return token;
      }
      debugPrint('⚠️ No FCM token found for receiver ${widget.receiverId}');
      return null;
    } catch (e) {
      debugPrint('❌ Error fetching FCM token: $e');
      return null;
    }
  }

  Future<void> _sendPushNotification(
    String token,
    String title,
    String body,
  ) async {
    final serviceAccountJson = dotenv.env['SERVICE_ACCOUNT_JSON'];
    if (serviceAccountJson == null) {
      debugPrint('❌ SERVICE_ACCOUNT_JSON not found in .env');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification service unavailable')),
      );
      return;
    }

    try {
      final credentials = ServiceAccountCredentials.fromJson(
        serviceAccountJson,
      );
      final client = await clientViaServiceAccount(credentials, [
        'https://www.googleapis.com/auth/cloud-platform',
      ]);
      debugPrint('🔑 Server Key: ${credentials.email}');

      final notificationData = {
        'message': {
          'token': token,
          'notification': {'title': title, 'body': body},
          'data': {
            'chatId': widget.chatId,
            'senderId': widget.senderId,
            'receiverId': widget.receiverId,
            'title': widget.receiverName,
            'receiverPhoto': widget.receiverPhoto,
          },
          'android': {
            'priority': 'high',
            'notification': {
              'channel_id': 'chat_channel',
              'visibility': 'public',
            },
          },
        },
      };

      debugPrint('📤 Payload: $notificationData');
      final response = await client.post(
        Uri.parse(
          'https://fcm.googleapis.com/v1/projects/signin-72f07/messages:send',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(notificationData),
      );

      client.close();
      if (response.statusCode == 200) {
        debugPrint('✅ Notification sent successfully to ${widget.receiverId}');
      } else {
        debugPrint('❌ Failed to send notification: ${response.body}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to send notification: ${response.body}')),
        );
      }
    } catch (e) {
      debugPrint('❌ Error sending notification: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send notification: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundImage: widget.receiverPhoto.isNotEmpty
                  ? CachedNetworkImageProvider(widget.receiverPhoto)
                  : null,
              child: widget.receiverPhoto.isEmpty
                  ? Text(
                      widget.receiverName[0].toUpperCase(),
                      style: const TextStyle(fontSize: 20),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Text(widget.receiverName),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('messages')
                  .doc(widget.chatId)
                  .collection('chat')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(child: Text('No messages yet'));
                }

                final messages = snapshot.data!.docs;
                return ListView.builder(
                  reverse: true,
                  controller: _scrollController,
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message =
                        messages[index].data() as Map<String, dynamic>;
                    final isSender = message['senderId'] == widget.senderId;
                    return ListTile(
                      title: Align(
                        alignment: isSender
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color:
                                isSender ? Colors.blue[100] : Colors.grey[200],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: isSender
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              if (message['imageUrl'] != null &&
                                  message['imageUrl'].isNotEmpty)
                                CachedNetworkImage(
                                  imageUrl: message['imageUrl'],
                                  width: 200,
                                  height: 200,
                                  placeholder: (context, url) =>
                                      const CircularProgressIndicator(),
                                  errorWidget: (context, url, error) =>
                                      const Icon(Icons.error),
                                ),
                              if (message['message'].isNotEmpty)
                                Text(message['message']),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.image),
                  onPressed: () async {
                    final picker = ImagePicker();
                    final image = await picker.pickImage(
                      source: ImageSource.gallery,
                    );
                    if (image != null) {
                      await _sendMessage(image: image);
                    }
                  },
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Type a message',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: () => _sendMessage(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
