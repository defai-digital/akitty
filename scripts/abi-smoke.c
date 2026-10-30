#include "akitty.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    assert(akitty_abi_version() == 1);
    const char *request = "{\"op\":\"version\"}";
    for (int i = 0; i < 1000; ++i) {
        AkittyBuffer b = akitty_request_v1((const uint8_t *)request, strlen(request));
        assert(b.data && b.len > 0 && b.len < 4096);
        char result[4096]; memcpy(result, b.data, b.len); result[b.len] = 0;
        assert(strstr(result, "\"ok\":true") != NULL);
        akitty_buffer_free_v1(b);
    }
    AkittyBuffer invalid = akitty_request_v1(NULL, 0);
    assert(invalid.data != NULL);
    akitty_buffer_free_v1(invalid);
    puts("C ABI version, response ownership, and invalid-buffer checks passed.");
}
