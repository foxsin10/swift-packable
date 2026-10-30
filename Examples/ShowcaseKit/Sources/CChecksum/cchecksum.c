#include "cchecksum.h"

uint32_t cchecksum_crc32(const uint8_t *bytes, size_t length) {
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < length; i++) {
    crc ^= bytes[i];
    for (int bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
  }
  return ~crc;
}
