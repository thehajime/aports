/* SVM thread root, TLS isolation, cancellation-point entry and join wait. */
#include <pthread.h>
#include <unistd.h>
#include <stdint.h>
#include <time.h>
#include <errno.h>
#include <sys/mman.h>

static __thread unsigned int thread_value;

static void *worker(void *argument)
{
	thread_value = 0x12345678;
	unsigned int *p = mmap(0, 4096, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if ((uintptr_t)p < 0x1000000000UL || (uintptr_t)p >= 0x1040000000UL)
		return (void *)11;
	*p = thread_value;
	if (*p != 0x12345678) return (void *)12;
	if (munmap(p, 4096)) return (void *)13;
	struct timespec pause = { .tv_nsec = 20000000 };
	if (nanosleep(&pause, 0)) return (void *)14;
	return argument;
}

int main(void)
{
	pthread_t thread;
	pthread_attr_t attr;
	size_t guard;
	void *result;

	thread_value = 0xfeed;
	if (pthread_attr_init(&attr)) return 21;
	if (pthread_attr_getguardsize(&attr, &guard) || guard) return 22;
	if (pthread_attr_setguardsize(&attr, 4096)) return 23;
	if (pthread_create(&thread, &attr, worker, (void *)0x42) != EINVAL)
		return 24;
	if (pthread_attr_setguardsize(&attr, 0)) return 25;
	for (unsigned i = 0; i < 2; i++) {
		int ret = pthread_create(&thread, i ? &attr : 0, worker, (void *)0x42);
		if (ret) return ret;
		ret = pthread_join(thread, &result);
		if (ret || result != (void *)0x42 || thread_value != 0xfeed)
			return 20;
	}
	pthread_attr_destroy(&attr);
	write(1, "MUSL_SVM_PTHREAD_OK\n", 20);
	return 0;
}
