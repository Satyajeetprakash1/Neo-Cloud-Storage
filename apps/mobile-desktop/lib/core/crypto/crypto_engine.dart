import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

class CryptoEngine {
  final AesGcm _aesGcm = AesGcm.with256bits();
  final Hmac _hmac = Hmac.sha256();
  final Sha256 _sha256 = Sha256();

  /// Derives a Deterministic Synthetic-IV and Chunk_Key using Convergent Encryption.
  /// 
  /// [chunkPlaintext] is the raw 4MB chunk data.
  /// [globalDomainSalt] is a fixed, globally shared salt used across the system 
  /// to ensure identical chunks produce identical keys.
  Future<Map<String, List<int>>> deriveConvergentKeys(
    List<int> chunkPlaintext,
    List<int> globalDomainSalt,
  ) async {
    // 1. Chunk_Key = HMAC-SHA256(Chunk_Plaintext, Global_Domain_Salt)
    final macKey = await _hmac.calculateMac(
      chunkPlaintext,
      secretKey: SecretKey(globalDomainSalt),
    );
    final chunkKey = macKey.bytes;

    // 2. IV = HMAC-SHA256(Chunk_Key, Chunk_Plaintext)[0..11] (96-bit IV)
    final ivMac = await _hmac.calculateMac(
      chunkPlaintext,
      secretKey: SecretKey(chunkKey),
    );
    final iv = ivMac.bytes.sublist(0, 12);

    return {
      'chunkKey': chunkKey,
      'iv': iv,
    };
  }

  /// Encrypts the chunk and returns the ciphertext and its deduplication hash.
  Future<Map<String, dynamic>> encryptAndHashChunk(
    List<int> chunkPlaintext,
    List<int> globalDomainSalt,
  ) async {
    final keys = await deriveConvergentKeys(chunkPlaintext, globalDomainSalt);
    final secretKey = SecretKey(keys['chunkKey']!);
    final nonce = keys['iv']!;

    // 3. Encrypt via AES-256-GCM
    final secretBox = await _aesGcm.encrypt(
      chunkPlaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    // The output format is usually Ciphertext + MAC tag.
    final ciphertextWithTag = secretBox.concatenation();

    // 4. Verification Hash = SHA-256(Ciphertext)
    final hash = await _sha256.hash(ciphertextWithTag);
    final chunkHash = hash.bytes;

    return {
      'ciphertext': ciphertextWithTag,
      'chunkHash': chunkHash,
      'chunkKey': keys['chunkKey']!,
    };
  }

  /// Master Key derivation (PBKDF2 is standard in cryptography package)
  Future<List<int>> deriveMasterKey(String password, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    
    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(password.codeUnits),
      nonce: salt,
    );
    
    return await secretKey.extractBytes();
  }
}
