bool is18mhLibrarySource(Map<String, dynamic> metadata) {
  final id = (metadata['sourceId'] as String? ?? '').trim().toLowerCase();
  final host = Uri.tryParse(metadata['detailUrl'] as String? ?? '')?.host
      .toLowerCase();
  return id == '18mh' ||
      host == '18mh.net' ||
      (host?.endsWith('.18mh.net') ?? false);
}

bool isSpecialLibrarySource(Map<String, dynamic> metadata) {
  final id = (metadata['sourceId'] as String? ?? '').trim().toLowerCase();
  final host = Uri.tryParse(metadata['detailUrl'] as String? ?? '')?.host
      .toLowerCase();
  return is18mhLibrarySource(metadata) ||
      id == 'yeshe' ||
      host == 'yeshezy1.com';
}
