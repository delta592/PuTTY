/*
 * puttygen-bridge.h — C API for the macOS PuTTYgen AppKit GUI (Phase 7.3).
 *
 * Swift imports this through the PuttygenBridge clang module. Do not
 * include putty.h from Swift.
 */

#ifndef PUTTY_MACOS_PUTTYGEN_BRIDGE_H
#define PUTTY_MACOS_PUTTYGEN_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PuttygenKey PuttygenKey;

typedef enum PuttygenKeyType {
    PUTTYGEN_KEY_RSA = 0,
    PUTTYGEN_KEY_ECDSA = 1,
    PUTTYGEN_KEY_ED25519 = 2,
} PuttygenKeyType;

typedef enum PuttygenLoadResult {
    PUTTYGEN_LOAD_OK = 0,
    PUTTYGEN_LOAD_NEED_PASSPHRASE,
    PUTTYGEN_LOAD_WRONG_PASSPHRASE,
    PUTTYGEN_LOAD_ERROR,
} PuttygenLoadResult;

/** Progress fraction in [0,1]; may be called from a worker thread. */
typedef void (*PuttygenProgressFn)(void *ctx, double fraction);

void puttygen_bridge_init(void);

PuttygenKey *puttygen_key_new(void);
void puttygen_key_free(PuttygenKey *key);

bool puttygen_key_has_key(const PuttygenKey *key);

/**
 * Generate a new SSH-2 key. Blocks until complete. Call from a background
 * queue; progress_fn may fire on the same thread.
 *
 * The key handle must remain valid for the full call. Callers must not
 * puttygen_key_free(key) (or destroy the owning UI) until this returns.
 *
 * bits: RSA modulus bits (e.g. 2048), ECDSA curve bits (256/384/521),
 * or ignored for Ed25519 (always 255).
 */
bool puttygen_key_generate(
    PuttygenKey *key, PuttygenKeyType type, int bits,
    PuttygenProgressFn progress_fn, void *progress_ctx,
    char **error_out);

/**
 * Probe whether path is encrypted. Sets *needs_passphrase.
 * Returns false on I/O / unsupported type (error_out set).
 */
bool puttygen_key_probe_file(
    const char *path, bool *needs_passphrase, char **error_out);

/**
 * Load a private key (PPK or OpenSSH). passphrase may be NULL/empty.
 * On NEED_PASSPHRASE / WRONG_PASSPHRASE, key is unchanged.
 */
PuttygenLoadResult puttygen_key_load(
    PuttygenKey *key, const char *path, const char *passphrase,
    char **error_out);

/** Save as PuTTY PPK. passphrase NULL/empty = unencrypted. */
bool puttygen_key_save_ppk(
    PuttygenKey *key, const char *path, const char *passphrase,
    char **error_out);

/** Export OpenSSH private key (auto format). */
bool puttygen_key_export_openssh(
    PuttygenKey *key, const char *path, const char *passphrase,
    char **error_out);

/** Save OpenSSH authorized_keys one-liner public key. */
bool puttygen_key_save_public(
    PuttygenKey *key, const char *path, char **error_out);

/** Heap strings; free with puttygen_free_string(). */
char *puttygen_key_fingerprint(const PuttygenKey *key);
char *puttygen_key_public_openssh(const PuttygenKey *key);
char *puttygen_key_comment(const PuttygenKey *key);
void puttygen_key_set_comment(PuttygenKey *key, const char *comment);

void puttygen_free_string(char *s);

/** Headless smoke: generate Ed25519, PPK round-trip. Returns 0 on OK. */
int puttygen_bridge_smoke(void);

#ifdef __cplusplus
}
#endif

#endif /* PUTTY_MACOS_PUTTYGEN_BRIDGE_H */
