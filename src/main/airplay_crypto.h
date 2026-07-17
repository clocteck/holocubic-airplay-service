/* Author: sunfang1cn@gmail.com */

#ifndef AIRPLAY_CRYPTO_H
#define AIRPLAY_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#define AIRPLAY_RSA_BYTES 256u
#define AIRPLAY_AES_BLOCK_BYTES 16u
#define AIRPLAY_AES128_ROUND_KEY_BYTES 176u

typedef struct airplay_aes128_context_t {
    uint8_t round_key[AIRPLAY_AES128_ROUND_KEY_BYTES];
} airplay_aes128_context_t;

#if defined(_WIN32) && defined(AIRPLAY_CRYPTO_TEST)
#define AIRPLAY_CRYPTO_API __declspec(dllexport)
#else
#define AIRPLAY_CRYPTO_API
#endif

AIRPLAY_CRYPTO_API void airplay_sha1(const uint8_t *data, size_t len, uint8_t digest[20]);

AIRPLAY_CRYPTO_API int airplay_rsa_pkcs1_sign_raw(const uint8_t *data,
                                                  size_t len,
                                                  uint8_t output[AIRPLAY_RSA_BYTES]);

AIRPLAY_CRYPTO_API int airplay_rsa_oaep_decrypt(const uint8_t cipher[AIRPLAY_RSA_BYTES],
                                                uint8_t *output,
                                                size_t output_capacity,
                                                size_t *output_len);

AIRPLAY_CRYPTO_API void airplay_aes128_cbc_decrypt(const uint8_t key[16],
                                                   const uint8_t iv[16],
                                                   const uint8_t *input,
                                                   uint8_t *output,
                                                   size_t len);

AIRPLAY_CRYPTO_API void airplay_aes128_init(airplay_aes128_context_t *ctx,
                                            const uint8_t key[16]);

AIRPLAY_CRYPTO_API void airplay_aes128_cbc_decrypt_ctx(const airplay_aes128_context_t *ctx,
                                                       const uint8_t iv[16],
                                                       const uint8_t *input,
                                                       uint8_t *output,
                                                       size_t len);

#endif
