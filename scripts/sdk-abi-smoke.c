#include "akitty.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Synthetic test requests only. Keep one core alive so the SDK test can use
// returned session IDs and verify its actual OSC output through the parser.
int main(void) {
    if (akitty_abi_version() != 1) return 1;
    const size_t capacity = 1024 * 1024 + 2;
    char *line = malloc(capacity);
    if (!line) return 1;
    while (fgets(line, (int)capacity, stdin)) {
        size_t length = strlen(line);
        if (!length || line[length - 1] != '\n') { free(line); return 1; }
        AkittyBuffer response = akitty_request_v1((const uint8_t *)line, length - 1);
        if (!response.data) { free(line); return 1; }
        size_t written = fwrite(response.data, 1, response.len, stdout);
        int complete = written == response.len;
        akitty_buffer_free_v1(response);
        if (!complete || putchar('\n') == EOF || fflush(stdout)) { free(line); return 1; }
    }
    free(line);
    return ferror(stdin) ? 1 : 0;
}
