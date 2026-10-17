#ifndef O66_NATIVE_H
#define O66_NATIVE_H
#include <stdint.h>
/* Borrowed for the duration of o66_payload only. No callbacks may outlive it. */
typedef struct {
    int32_t result;
    uint32_t abi, input, output, control, ipsr, stack, done;
} o66_mailbox;
int o66_payload(volatile o66_mailbox *mailbox);
#endif
