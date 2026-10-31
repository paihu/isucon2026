// 画像 URL の署名（HMAC-SHA256 を 1000 回繰り返す）。Ruby から 1 回ずつ呼ぶと呼び出しの手間が計算の数倍かかるため、
// 繰り返しを C で回す。鍵でパッドした内側・外側の状態を先に作り、毎回は複製して続きだけ計算する。
#define OPENSSL_SUPPRESS_DEPRECATED
#include <openssl/sha.h>
#include <string.h>

void isureal_iterated_hmac_sha256(const unsigned char *key, size_t key_len, const unsigned char *msg, size_t msg_len,
                                  int iterations, unsigned char *out) {
  unsigned char k[SHA256_CBLOCK] = {0}, pad[SHA256_CBLOCK], inner_digest[SHA256_DIGEST_LENGTH];
  SHA256_CTX inner, outer, ctx;

  if (key_len > SHA256_CBLOCK) {
    SHA256(key, key_len, k);
  } else {
    memcpy(k, key, key_len);
  }
  for (int i = 0; i < SHA256_CBLOCK; i++) pad[i] = k[i] ^ 0x36;
  SHA256_Init(&inner);
  SHA256_Update(&inner, pad, SHA256_CBLOCK);
  for (int i = 0; i < SHA256_CBLOCK; i++) pad[i] = k[i] ^ 0x5c;
  SHA256_Init(&outer);
  SHA256_Update(&outer, pad, SHA256_CBLOCK);

  const unsigned char *value = msg;
  size_t value_len = msg_len;
  for (int i = 0; i < iterations; i++) {
    ctx = inner;
    SHA256_Update(&ctx, value, value_len);
    SHA256_Final(inner_digest, &ctx);
    ctx = outer;
    SHA256_Update(&ctx, inner_digest, SHA256_DIGEST_LENGTH);
    SHA256_Final(out, &ctx);
    value = out;
    value_len = SHA256_DIGEST_LENGTH;
  }
}
