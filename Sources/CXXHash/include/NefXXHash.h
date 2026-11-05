#ifndef NEF_XXHASH_H
#define NEF_XXHASH_H
#include <stdint.h>
#include <stddef.h>
typedef struct NefXXHState NefXXHState;
NefXXHState *nef_xxh64_create(void);
void nef_xxh64_free(NefXXHState *state);
void nef_xxh64_update(NefXXHState *state, const void *data, size_t length);
uint64_t nef_xxh64_digest(const NefXXHState *state);
#endif
