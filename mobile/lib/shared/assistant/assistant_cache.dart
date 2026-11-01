import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/nip44.dart';

/// A report page can exceed NIP-44's per-message plaintext limit. Chunk UTF-8
/// bytes rather than Dart strings so non-BMP evidence is not split or lost.
String encodeAssistantCache(Uint8List key, String plaintext) {
  final bytes = utf8.encode(plaintext);
  final chunks = <String>[];
  for (var offset = 0; offset < bytes.length; offset += 32768) {
    chunks.add(
      nip44Encrypt(
        key,
        base64Encode(
          Uint8List.sublistView(
            bytes,
            offset,
            min(offset + 32768, bytes.length),
          ),
        ),
      ),
    );
  }
  return jsonEncode(chunks);
}

String decodeAssistantCache(Uint8List key, String encoded) {
  final chunks = jsonDecode(encoded) as List;
  final bytes = BytesBuilder(copy: false);
  for (final chunk in chunks) {
    bytes.add(base64Decode(nip44Decrypt(key, chunk as String)));
  }
  return utf8.decode(bytes.takeBytes());
}
