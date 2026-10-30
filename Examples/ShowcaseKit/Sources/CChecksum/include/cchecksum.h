#ifndef CCHECKSUM_H
#define CCHECKSUM_H

#include <stddef.h>
#include <stdint.h>

/// CRC-32 (IEEE 802.3) of `length` bytes.
uint32_t cchecksum_crc32(const uint8_t *bytes, size_t length);

#endif
