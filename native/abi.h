/* o66cn 3.1.28 code-view Thumb entries used by the bridge. See docs/abi.md. */
#ifndef O66_BLE_ABI_H
#define O66_BLE_ABI_H
#include <stdint.h>
#include <stddef.h>
#define FW(address, result, ...) ((result (*)(__VA_ARGS__))(uintptr_t)(address))
// 0x0c121d74 -> mm_zalloc 0x0c121d0c -> mm_malloc + memset(0).
// 0x0c121dc8 instead calls mm_malloc directly and MUST NOT be used here.
#define zalloc FW(0x0c121d75, void *, uint32_t)
#define release FW(0x0c11eee9, void, void *)
#define delay_us FW(0x0c11ed99, int, uint32_t)
#define spawn_attr_init FW(0x0c11372d, int, void *)
#define task_spawn FW(0x0c50fce9, int, const char *, int (*)(int,char **), const void *, const void *, char *const *, char *const *)
#define instance_create FW(0x0c4cc9b1, void *, void)
#define client_create FW(0x0c4c6529, int, void *, void **, const void *)
#define client_connect FW(0x0c50548d, int, void *, const void *)
#define client_disconnect FW(0x0c4c6625, int, void *)
#define discover FW(0x0c4c6651, int, void *, const void *)
#define get_attribute FW(0x0c4c6691, int, void *, uint16_t, void *)
#define read_request FW(0x0c4c66cd, int, void *, uint16_t)
#define write_request FW(0x0c4c68cb, int, void *, uint16_t, const void *, uint16_t)
#define subscribe FW(0x0c4c66fb, int, void *, uint16_t, uint16_t)
#define scan_start FW(0x0c4cc829, void *, void *, const void *, const void *, const void *)
#define scan_stop FW(0x0c4c6ec3, int, void *, void *)
#define clean_d FW(0x0c56a2ab, void, void)
#define invalidate_i FW(0x0c0a181f, void, void)
#define barrier FW(0x0c5590bf, void, void)
#endif
