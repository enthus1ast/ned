#include "mathx.h"
#include <string.h>
int mx_errno = 0;
int mx_add(int a, int b) { return a + b; }
double mx_scale(double x, float factor) { return x * factor; }
size_t mx_count(const char *text) { return strlen(text); }
void mx_fill(uint8_t *buf, size_t len, uint8_t value) { memset(buf, value, len); }
const char *mx_name(void) { return "mathx"; }
