import 'dart:io';
import 'package:cross_file/cross_file.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';

const String kAdminEmail = 'sameraoaad@gmail.com';

class AuthService {
  AuthService._internal();
  static final AuthService instance = AuthService._internal();

  final SupabaseClient _client = Supabase.instance.client;

  bool get isLoggedIn => _client.auth.currentSession != null;
  User? get currentUser => _client.auth.currentUser;

  bool get isCurrentUserAdmin {
    final email = _client.auth.currentUser?.email;
    return email != null && email.toLowerCase() == kAdminEmail.toLowerCase();
  }

  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String fullName,
    String? phone,
  }) async {
    final response = await _client.auth.signUp(
      email: email,
      password: password,
      data: {
        'full_name': fullName,
        if (phone != null) 'phone': phone,
      },
    );
    return response;
  }

  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    return await _client.auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
  }
}

class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  final SupabaseClient _client = Supabase.instance.client;
  SupabaseClient get client => _client;

  bool get isAdmin {
    final email = _client.auth.currentUser?.email;
    return email != null && email.toLowerCase() == kAdminEmail.toLowerCase();
  }

  String? get currentUserId => _client.auth.currentUser?.id;

  Future<String> compressAndUploadImage(File file, {required String adId}) async {
    final compressedFile = await _compressImage(file);
    final fileBytes = await compressedFile.readAsBytes();
    final ext = p.extension(compressedFile.path).replaceAll('.', '');
    final fileName = '$adId/${DateTime.now().millisecondsSinceNow}.$ext';

    await _client.storage.from(AppConfig.adsImagesBucket).uploadBinary(
          fileName,
          fileBytes,
          fileOptions: FileOptions(
            contentType: 'image/$ext',
            upsert: false,
          ),
        );

    final publicUrl = _client.storage.from(AppConfig.adsImagesBucket).getPublicUrl(fileName);
    return publicUrl;
  }

  Future<File> _compressImage(File file) async {
    final dir = await getTemporaryDirectory();
    final targetPath = p.join(
      dir.path,
      '${DateTime.now().millisecondsSinceEpoch}${p.extension(file.path).isEmpty ? '.jpg' : p.extension(file.path)}',
    );

    final XFile? result = await FlutterImageCompress.compressAndGetFile(
      file.absolute.path,
      targetPath,
      quality: 70,
      minWidth: 1280,
      minHeight: 1280,
      format: CompressFormat.jpeg,
    );

    if (result == null) return file;
    return File(result.path);
  }

  Future<void> deleteAdImages(List<String> imageUrls) async {
    final paths = imageUrls.map((url) {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      final idx = segments.indexOf(AppConfig.adsImagesBucket);
      return segments.sublist(idx + 1).join('/');
    }).toList();
    if (paths.isEmpty) return;
    await _client.storage.from(AppConfig.adsImagesBucket).remove(paths);
  }

  Future<String> createAdRecord(Map<String, dynamic> data) async {
    final response = await _client.from('ads').insert(data).select('id').single();
    return response['id'] as String;
  }

  Future<Map<String, dynamic>> fetchAdById(String adId) async {
    await _client.rpc('increment_ad_views', params: {'ad_id_input': adId}).catchError((_) {});
    final response = await _client.from('ads').select().eq('id', adId).single();
    return response;
  }

  Future<List<Map<String, dynamic>>> searchAds({
    String? keyword,
    String? province,
    String? categoryId,
    String? condition,
    double? minPrice,
    double? maxPrice,
    int limit = 30,
    int offset = 0,
  }) async {
    var query = _client.from('ads').select().eq('is_active', true);

    if (keyword != null && keyword.trim().isNotEmpty) {
      query = query.ilike('title', '%${keyword.trim()}%');
    }
    if (province != null && province.isNotEmpty) {
      query = query.eq('province', province);
    }
    if (categoryId != null && categoryId.isNotEmpty) {
      query = query.eq('category_id', categoryId);
    }
    if (minPrice != null) {
      query = query.gte('price_syp', minPrice);
    }
    if (maxPrice != null) {
      query = query.lte('price_syp', maxPrice);
    }

    final response = await query
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    return List<Map<String, dynamic>>.from(response);
  }
}

class MarketplaceService {
  MarketplaceService._internal();
  static final MarketplaceService instance = MarketplaceService._internal();
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<Map<String, dynamic>>> fetchCategories() async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from('categories')
          .select()
          .order('sort_order', ascending: true);
      return rows;
    } on PostgrestException {
      return [];
    }
  }
}

class MonetizationChatService {
  MonetizationChatService._();
  static final MonetizationChatService instance = MonetizationChatService._();
  SupabaseClient get _client => Supabase.instance.client;

  Future<List<Map<String, dynamic>>> fetchMessages(String conversationId) async {
    final data = await _client
        .from('chat_messages')
        .select()
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true);
    return List<Map<String, dynamic>>.from(data);
  }

  Future<void> sendMessage({
    required String conversationId,
    required String content,
  }) async {
    final senderId = _client.auth.currentUser?.id;
    if (senderId == null) throw StateError('يجب تسجيل الدخول لإرسال رسالة');
    await _client.from('chat_messages').insert({
      'conversation_id': conversationId,
      'sender_id': senderId,
      'content': content,
    });
  }

  Future<void> markMessagesAsRead(String conversationId) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;
    await _client
        .from('chat_messages')
        .update({'is_read': true})
        .eq('conversation_id', conversationId)
        .neq('sender_id', userId);
  }

  RealtimeChannel subscribeToConversationMessages({
    required String conversationId,
    required void Function(Map<String, dynamic> message) onNewMessage,
  }) {
    final channel = _client
        .channel('chat_messages:$conversationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: conversationId,
          ),
          callback: (payload) {
            onNewMessage(payload.newRecord);
          },
        );
    channel.subscribe();
    return channel;
  }

  Future<void> unsubscribe(RealtimeChannel channel) async {
    await _client.removeChannel(channel);
  }
}