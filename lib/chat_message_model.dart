import 'package:hive/hive.dart';

part 'chat_message_model.g.dart';

@HiveType(typeId: 0)
class ChatMessage {
  @HiveField(0)
  final String id;
  @HiveField(1)
  final String chatId;
  @HiveField(2)
  final String senderId;
  @HiveField(3)
  final String receiverId;
  @HiveField(4)
  final String? text;
  @HiveField(5)
  final String? imageUrl;
  @HiveField(6)
  final DateTime timestamp;
  @HiveField(7)
  final String status;
  @HiveField(8)
  final bool seen;

  ChatMessage({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.receiverId,
    this.text,
    this.imageUrl,
    required this.timestamp,
    required this.status,
    required this.seen,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'chatId': chatId,
      'senderId': senderId,
      'receiverId': receiverId,
      'text': text,
      'imageUrl': imageUrl,
      'timestamp': timestamp.toIso8601String(),
      'status': status,
      'seen': seen,
    };
  }
  
  ChatMessage copyWith({
    String? id,
    String? chatId,
    String? senderId,
    String? receiverId,
    String? text,
    String? imageUrl,
    DateTime? timestamp,
    String? status,
    bool? seen,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      text: text ?? this.text,
      imageUrl: imageUrl ?? this.imageUrl,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      seen: seen ?? this.seen,
    );
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    return ChatMessage(
      id: map['id'] ?? '',
      chatId: map['chatId'] ?? '',
      senderId: map['senderId'] ?? '',
      receiverId: map['receiverId'] ?? '',
      text: map['text'],
      imageUrl: map['imageUrl'],
      timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
      status: map['status'] ?? 'sent',
      seen: map['seen'] ?? false,
    );
  }
}
