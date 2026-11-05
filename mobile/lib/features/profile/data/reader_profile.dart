import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';

const presetAvatarNames = ['向日葵星环', '几何日落', '宇航猫', '复古电脑猫', '西瓜泳池', '光谱丝带'];

String presetAvatarAsset(int id) => 'assets/avatars/avatar-$id.png';

class ReaderProfile {
  const ReaderProfile({this.nickname = defaultNickname, this.avatarId});

  static const defaultNickname = '本地读者';
  final String nickname;
  final int? avatarId;
}

final readerProfileProvider =
    AsyncNotifierProvider<ReaderProfileStore, ReaderProfile>(
      ReaderProfileStore.new,
    );

class ReaderProfileStore extends AsyncNotifier<ReaderProfile> {
  static const _key = 'local:reader-profile';

  @override
  Future<ReaderProfile> build() async {
    final sync = await ref.watch(syncRepositoryProvider.future);
    final saved = await sync.meta(_key);
    if (saved == null) return const ReaderProfile();
    try {
      final json = jsonDecode(saved);
      if (json is Map<String, dynamic>) {
        return _profile(json['nickname'], json['avatarId']);
      }
    } on FormatException {
      return const ReaderProfile();
    }
    return const ReaderProfile();
  }

  Future<void> save(String nickname, int? avatarId) async {
    final profile = _profile(nickname, avatarId);
    final sync = await ref.read(syncRepositoryProvider.future);
    await sync.setMeta(
      _key,
      jsonEncode({'nickname': profile.nickname, 'avatarId': profile.avatarId}),
    );
    if (ref.mounted) state = AsyncData(profile);
  }

  ReaderProfile _profile(Object? name, Object? id) {
    final nickname = name is String ? name.trim() : '';
    return ReaderProfile(
      nickname: nickname.isEmpty ? ReaderProfile.defaultNickname : nickname,
      avatarId: id is int && id >= 1 && id <= presetAvatarNames.length
          ? id
          : null,
    );
  }
}
