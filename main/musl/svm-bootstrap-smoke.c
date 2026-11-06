/* SVM root must be installed before constructors and after final TLS setup. */
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#ifdef SVM_SMOKE_MALLOC
#include <stdlib.h>
#include <stdio.h>
#endif

__thread volatile unsigned char tls_blob[65536];
static volatile int constructor_ok;

__attribute__((constructor)) static void check_constructor(void)
{
	volatile unsigned *p = mmap(0, 4096, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if ((uintptr_t)p < 0x1000000000UL || (uintptr_t)p >= 0x1040000000UL)
		_exit(11);
	*p = 0x1234abcd;
	if (*p != 0x1234abcd || munmap((void *)p, 4096)) _exit(12);
	tls_blob[0] = 19;
	tls_blob[65535] = 23;
	constructor_ok = 1;
}

int main(void)
{
	if (!constructor_ok || tls_blob[0] != 19 || tls_blob[65535] != 23)
		return 14;
	write(1, "MUSL_SVM_BOOTSTRAP_OK\n", 22);
#ifdef SVM_SMOKE_MALLOC
	volatile unsigned char *p = malloc(131072);
	if (!p) return 15;
	for (unsigned i = 0; i < 131072; i++) p[i] = (unsigned char)i;
	for (unsigned i = 0; i < 131072; i++)
		if (p[i] != (unsigned char)i) return 16;
	free((void *)p);
	puts("MUSL_SVM_MALLOC_OK");
#endif
	return 0;
}
