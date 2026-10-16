#ifndef MATHX_H
#define MATHX_H
#include <stddef.h>
#include <stdint.h>

/* add two numbers */
int mx_add(int a, int b);
double mx_scale(double x, float factor);
size_t mx_count(const char *text);
void mx_fill(uint8_t *buf, size_t len, uint8_t value);
const char *mx_name(void);
int mx_printf(const char *fmt, ...);
typedef struct { int x, y; } MxPoint;
MxPoint mx_origin(void);
#define MX_MAX(a, b) ((a) > (b) ? (a) : (b))
#define MX_VERSION 3
extern int mx_errno;
#endif
