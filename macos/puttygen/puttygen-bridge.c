/*
 * puttygen-bridge.c — keygen load/generate/save for macOS PuTTYgen.app.
 *
 * Ports the core workflows from windows/puttygen.c / cmdgen.c without
 * embedding either main().
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "putty.h"
#include "ssh.h"
#include "sshkeygen.h"

#include "puttygen-bridge.h"

struct PuttygenKey {
    ssh2_userkey *ukey;
};

struct bridge_progress {
    ProgressReceiver rec;
    PuttygenProgressFn fn;
    void *ctx;
    double last;
};

static ProgressPhase bridge_progress_add_linear(ProgressReceiver *prog, double c)
{
    ProgressPhase ph = { .n = 0 };
    (void)prog;
    (void)c;
    return ph;
}

static ProgressPhase bridge_progress_add_probabilistic(
    ProgressReceiver *prog, double c, double p)
{
    ProgressPhase ph = { .n = 1 };
    (void)prog;
    (void)c;
    (void)p;
    return ph;
}

static void bridge_progress_start_phase(ProgressReceiver *prog, ProgressPhase p)
{
    (void)prog;
    (void)p;
}

static void bridge_progress_report(ProgressReceiver *prog, double fraction)
{
    struct bridge_progress *bp = container_of(prog, struct bridge_progress, rec);

    if (fraction < 0.0)
        fraction = 0.0;
    if (fraction > 1.0)
        fraction = 1.0;
    if (fraction + 0.001 < bp->last)
        return;
    bp->last = fraction;
    if (bp->fn)
        bp->fn(bp->ctx, fraction);
}

static void bridge_progress_report_attempt(ProgressReceiver *prog)
{
    struct bridge_progress *bp = container_of(prog, struct bridge_progress, rec);
    double next = bp->last + 0.01;
    if (next > 0.99)
        next = 0.99;
    bridge_progress_report(prog, next);
}

static void bridge_progress_phase_complete(ProgressReceiver *prog)
{
    bridge_progress_report(prog, 1.0);
}

static const ProgressReceiverVtable bridge_progress_vt = {
    .add_linear = bridge_progress_add_linear,
    .add_probabilistic = bridge_progress_add_probabilistic,
    .ready = null_progress_ready,
    .start_phase = bridge_progress_start_phase,
    .report = bridge_progress_report,
    .report_attempt = bridge_progress_report_attempt,
    .report_phase_complete = bridge_progress_phase_complete,
};

static void puttygen_key_clear(PuttygenKey *key)
{
    if (!key || !key->ukey)
        return;
    if (key->ukey->key)
        ssh_key_free(key->ukey->key);
    sfree(key->ukey->comment);
    sfree(key->ukey);
    key->ukey = NULL;
}

static char *dup_error(const char *msg)
{
    return dupstr(msg ? msg : "Unknown error");
}

void puttygen_bridge_init(void)
{
    static bool done;
    if (done)
        return;
    done = true;
    /* Seeds PRNG via noise_get_heavy() (/dev/urandom + process list). */
    random_setup_special();
}

PuttygenKey *puttygen_key_new(void)
{
    PuttygenKey *key = snew(PuttygenKey);
    key->ukey = NULL;
    return key;
}

void puttygen_key_free(PuttygenKey *key)
{
    if (!key)
        return;
    puttygen_key_clear(key);
    sfree(key);
}

bool puttygen_key_has_key(const PuttygenKey *key)
{
    return key && key->ukey && key->ukey->key;
}

void puttygen_free_string(char *s)
{
    sfree(s);
}

static char *default_comment_for(PuttygenKeyType type, int bits)
{
    char buf[80];
    struct tm tm = ltime();

    if (type == PUTTYGEN_KEY_ECDSA)
        strftime(buf, sizeof(buf), "ecdsa-key-%Y%m%d", &tm);
    else if (type == PUTTYGEN_KEY_ED25519)
        strftime(buf, sizeof(buf), "ed25519-key-%Y%m%d", &tm);
    else {
        (void)bits;
        strftime(buf, sizeof(buf), "rsa-key-%Y%m%d", &tm);
    }
    return dupstr(buf);
}

bool puttygen_key_generate(
    PuttygenKey *key, PuttygenKeyType type, int bits,
    PuttygenProgressFn progress_fn, void *progress_ctx,
    char **error_out)
{
    char *entropy;
    int entropy_bytes;
    struct bridge_progress prog;
    ssh2_userkey *ukey = NULL;

    if (error_out)
        *error_out = NULL;
    if (!key) {
        if (error_out)
            *error_out = dup_error("Invalid key handle");
        return false;
    }

    puttygen_bridge_init();

    if (type == PUTTYGEN_KEY_ED25519)
        bits = 255;
    else if (type == PUTTYGEN_KEY_ECDSA) {
        if (bits != 256 && bits != 384 && bits != 521)
            bits = 384;
    } else if (bits < 1024)
        bits = 2048;

    entropy_bytes = bits / 8;
    if (entropy_bytes < 32)
        entropy_bytes = 32;
    entropy = get_random_data(entropy_bytes, NULL);
    if (!entropy) {
        if (error_out)
            *error_out = dup_error("Failed to collect entropy from /dev/urandom");
        return false;
    }
    random_reseed(make_ptrlen(entropy, entropy_bytes));
    smemclr(entropy, entropy_bytes);
    sfree(entropy);

    memset(&prog, 0, sizeof(prog));
    prog.rec.vt = &bridge_progress_vt;
    prog.fn = progress_fn;
    prog.ctx = progress_ctx;

    if (progress_fn)
        progress_fn(progress_ctx, 0.0);

    ukey = snew(ssh2_userkey);
    ukey->key = NULL;
    ukey->comment = NULL;

    if (type == PUTTYGEN_KEY_RSA) {
        RSAKey *rsakey = snew(RSAKey);
        PrimeGenerationContext *pgc =
            primegen_new_context(&primegen_probabilistic);
        if (!rsa_generate(rsakey, bits, false, pgc, &prog.rec)) {
            primegen_free_context(pgc);
            sfree(rsakey);
            sfree(ukey);
            if (error_out)
                *error_out = dup_error("RSA key generation failed");
            return false;
        }
        primegen_free_context(pgc);
        rsakey->comment = NULL;
        ukey->key = &rsakey->sshk;
    } else if (type == PUTTYGEN_KEY_ECDSA) {
        struct ecdsa_key *ek = snew(struct ecdsa_key);
        if (!ecdsa_generate(ek, bits)) {
            sfree(ek);
            sfree(ukey);
            if (error_out)
                *error_out = dup_error("ECDSA key generation failed");
            return false;
        }
        ukey->key = &ek->sshk;
    } else {
        struct eddsa_key *ek = snew(struct eddsa_key);
        if (!eddsa_generate(ek, bits)) {
            sfree(ek);
            sfree(ukey);
            if (error_out)
                *error_out = dup_error("Ed25519 key generation failed");
            return false;
        }
        ukey->key = &ek->sshk;
    }

    ukey->comment = default_comment_for(type, bits);
    puttygen_key_clear(key);
    key->ukey = ukey;

    if (progress_fn)
        progress_fn(progress_ctx, 1.0);
    return true;
}

bool puttygen_key_probe_file(
    const char *path, bool *needs_passphrase, char **error_out)
{
    Filename *fn;
    int type;
    char *comment = NULL;
    bool encrypted = false;

    if (error_out)
        *error_out = NULL;
    if (needs_passphrase)
        *needs_passphrase = false;
    if (!path || !path[0]) {
        if (error_out)
            *error_out = dup_error("No path");
        return false;
    }

    fn = filename_from_str(path);
    type = key_type(fn);
    if (type == SSH_KEYTYPE_SSH2) {
        encrypted = ppk_encrypted_f(fn, &comment);
    } else if (import_possible(type)) {
        encrypted = import_encrypted(fn, type, &comment);
    } else {
        filename_free(fn);
        if (error_out)
            *error_out = dupprintf("Unsupported key type: %s",
                                   key_type_to_str(type));
        return false;
    }
    sfree(comment);
    filename_free(fn);
    if (needs_passphrase)
        *needs_passphrase = encrypted;
    return true;
}

PuttygenLoadResult puttygen_key_load(
    PuttygenKey *key, const char *path, const char *passphrase,
    char **error_out)
{
    Filename *fn;
    int type, realtype;
    const char *errmsg = NULL;
    ssh2_userkey *ukey = NULL;
    char *pass = passphrase ? (char *)passphrase : (char *)"";

    if (error_out)
        *error_out = NULL;
    if (!key || !path) {
        if (error_out)
            *error_out = dup_error("Invalid arguments");
        return PUTTYGEN_LOAD_ERROR;
    }

    puttygen_bridge_init();
    fn = filename_from_str(path);
    type = realtype = key_type(fn);

    if (type != SSH_KEYTYPE_SSH2 && import_possible(type)) {
        type = import_target_type(type);
    }

    if (type == SSH_KEYTYPE_SSH2 && realtype == SSH_KEYTYPE_SSH2) {
        if (ppk_encrypted_f(fn, NULL) && (!passphrase || !passphrase[0])) {
            filename_free(fn);
            return PUTTYGEN_LOAD_NEED_PASSPHRASE;
        }
        ukey = ppk_load_f(fn, pass, &errmsg);
    } else if (import_possible(realtype)) {
        if (import_encrypted(fn, realtype, NULL) &&
            (!passphrase || !passphrase[0])) {
            filename_free(fn);
            return PUTTYGEN_LOAD_NEED_PASSPHRASE;
        }
        ukey = import_ssh2(fn, realtype, pass, &errmsg);
    } else {
        filename_free(fn);
        if (error_out)
            *error_out = dupprintf("Cannot load key type: %s",
                                   key_type_to_str(realtype));
        return PUTTYGEN_LOAD_ERROR;
    }
    filename_free(fn);

    if (ukey == SSH2_WRONG_PASSPHRASE)
        return PUTTYGEN_LOAD_WRONG_PASSPHRASE;
    if (!ukey) {
        if (error_out)
            *error_out = dup_error(errmsg ? errmsg : "Failed to load key");
        return PUTTYGEN_LOAD_ERROR;
    }

    puttygen_key_clear(key);
    key->ukey = ukey;
    return PUTTYGEN_LOAD_OK;
}

bool puttygen_key_save_ppk(
    PuttygenKey *key, const char *path, const char *passphrase,
    char **error_out)
{
    Filename *fn;
    bool ok;
    const char *pass = passphrase ? passphrase : "";

    if (error_out)
        *error_out = NULL;
    if (!puttygen_key_has_key(key) || !path) {
        if (error_out)
            *error_out = dup_error("No key to save");
        return false;
    }

    puttygen_bridge_init();
    if (pass[0])
        random_ref();

    fn = filename_from_str(path);
    ok = ppk_save_f(fn, key->ukey, pass, &ppk_save_default_parameters);
    filename_free(fn);
    if (!ok && error_out)
        *error_out = dup_error("Failed to write PPK file");
    return ok;
}

bool puttygen_key_export_openssh(
    PuttygenKey *key, const char *path, const char *passphrase,
    char **error_out)
{
    Filename *fn;
    bool ok;
    char *pass = passphrase ? (char *)passphrase : (char *)"";

    if (error_out)
        *error_out = NULL;
    if (!puttygen_key_has_key(key) || !path) {
        if (error_out)
            *error_out = dup_error("No key to export");
        return false;
    }

    puttygen_bridge_init();
    random_ref();

    fn = filename_from_str(path);
    ok = export_ssh2(fn, SSH_KEYTYPE_OPENSSH_AUTO, key->ukey, pass);
    filename_free(fn);
    if (!ok && error_out)
        *error_out = dup_error("Failed to export OpenSSH private key");
    return ok;
}

bool puttygen_key_save_public(
    PuttygenKey *key, const char *path, char **error_out)
{
    FILE *fp;
    strbuf *pub;

    if (error_out)
        *error_out = NULL;
    if (!puttygen_key_has_key(key) || !path) {
        if (error_out)
            *error_out = dup_error("No key to save");
        return false;
    }

    {
        Filename *fn = filename_from_str(path);
        pub = strbuf_new();
        ssh_key_public_blob(key->ukey->key, BinarySink_UPCAST(pub));
        fp = f_open(fn, "w", true);
        filename_free(fn);
    }
    if (!fp) {
        strbuf_free(pub);
        if (error_out)
            *error_out = dup_error("Cannot open public key file for writing");
        return false;
    }
    ssh2_write_pubkey(fp, key->ukey->comment,
                      pub->s, pub->len,
                      SSH_KEYTYPE_SSH2_PUBLIC_OPENSSH);
    {
        bool bad = ferror(fp);

        if (fclose(fp) != 0)
            bad = true;
        strbuf_free(pub);
        if (bad) {
            if (error_out)
                *error_out = dup_error("Failed writing public key file");
            return false;
        }
    }
    return true;
}

char *puttygen_key_fingerprint(const PuttygenKey *key)
{
    if (!puttygen_key_has_key(key))
        return NULL;
    return ssh2_fingerprint(key->ukey->key, SSH_FPTYPE_DEFAULT);
}

char *puttygen_key_public_openssh(const PuttygenKey *key)
{
    if (!puttygen_key_has_key(key))
        return NULL;
    return ssh2_pubkey_openssh_str(key->ukey);
}

char *puttygen_key_comment(const PuttygenKey *key)
{
    if (!puttygen_key_has_key(key) || !key->ukey->comment)
        return dupstr("");
    return dupstr(key->ukey->comment);
}

void puttygen_key_set_comment(PuttygenKey *key, const char *comment)
{
    if (!puttygen_key_has_key(key))
        return;
    sfree(key->ukey->comment);
    key->ukey->comment = dupstr(comment ? comment : "");
}

int puttygen_bridge_smoke(void)
{
    PuttygenKey *key;
    char *err = NULL;
    char *fp = NULL;
    char *pub = NULL;
    char tmp_ppk[] = "/tmp/puttygen-smoke-XXXXXX.ppk";
    int fd;
    PuttygenLoadResult lr;

    puttygen_bridge_init();

    key = puttygen_key_new();
    if (!puttygen_key_generate(key, PUTTYGEN_KEY_ED25519, 255, NULL, NULL, &err)) {
        fprintf(stderr, "puttygen_bridge_smoke: generate failed: %s\n",
                err ? err : "?");
        sfree(err);
        puttygen_key_free(key);
        return 1;
    }

    fp = puttygen_key_fingerprint(key);
    pub = puttygen_key_public_openssh(key);
    if (!fp || !pub || !fp[0] || !pub[0]) {
        fprintf(stderr, "puttygen_bridge_smoke: missing fingerprint/pubkey\n");
        puttygen_free_string(fp);
        puttygen_free_string(pub);
        puttygen_key_free(key);
        return 2;
    }
    puttygen_free_string(fp);
    puttygen_free_string(pub);

    fd = mkstemps(tmp_ppk, 4);
    if (fd < 0) {
        fprintf(stderr, "puttygen_bridge_smoke: mkstemps failed\n");
        puttygen_key_free(key);
        return 3;
    }
    close(fd);

    if (!puttygen_key_save_ppk(key, tmp_ppk, "smoke-pass", &err)) {
        fprintf(stderr, "puttygen_bridge_smoke: save failed: %s\n",
                err ? err : "?");
        sfree(err);
        unlink(tmp_ppk);
        puttygen_key_free(key);
        return 4;
    }

    puttygen_key_clear(key);
    lr = puttygen_key_load(key, tmp_ppk, "smoke-pass", &err);
    unlink(tmp_ppk);
    if (lr != PUTTYGEN_LOAD_OK) {
        fprintf(stderr, "puttygen_bridge_smoke: reload failed (%d): %s\n",
                (int)lr, err ? err : "?");
        sfree(err);
        puttygen_key_free(key);
        return 5;
    }

    puttygen_key_free(key);
    puts("puttygen_bridge_smoke: ok");
    return 0;
}
