#include "NefXXHash.h"
#define XXH_NAMESPACE NEF_
#define XXH_STATIC_LINKING_ONLY
#define XXH_IMPLEMENTATION
#include "xxhash.h"
#include <stdlib.h>
struct NefXXHState { XXH64_state_t *value; };
NefXXHState *nef_xxh64_create(void) {
    NefXXHState *state = malloc(sizeof(*state));
    if (!state) return NULL;
    state->value = XXH64_createState();
    if (!state->value) { free(state); return NULL; }
    XXH64_reset(state->value, 0);
    return state;
}
void nef_xxh64_free(NefXXHState *state) {
    if (state) { XXH64_freeState(state->value); free(state); }
}
void nef_xxh64_update(NefXXHState *state, const void *data, size_t length) {
    XXH64_update(state->value, data, length);
}
uint64_t nef_xxh64_digest(const NefXXHState *state) {
    return XXH64_digest(state->value);
}
