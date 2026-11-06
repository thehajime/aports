/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <time.h>
#include <unistd.h>

struct state {
	pthread_mutex_t mutex;
	pthread_cond_t condition;
	pthread_mutex_t robust;
	sem_t semaphore;
	_Atomic int entered;
	int value;
};
static struct state *state;

static void *mutex_worker(void *unused)
{
	(void)unused;
	atomic_store(&state->entered, 1);
	if (pthread_mutex_lock(&state->mutex))
		return (void *)1;
	state->value++;
	return (void *)(long)pthread_mutex_unlock(&state->mutex);
}

static void *condition_worker(void *unused)
{
	(void)unused;
	if (pthread_mutex_lock(&state->mutex))
		return (void *)1;
	state->value = 42;
	if (pthread_cond_signal(&state->condition))
		return (void *)1;
	return (void *)(long)pthread_mutex_unlock(&state->mutex);
}

static void *robust_worker(void *unused)
{
	(void)unused;
	return (void *)(long)pthread_mutex_lock(&state->robust);
}

static void *semaphore_worker(void *unused)
{
	(void)unused;
	usleep(10000);
	state->value = 77;
	return (void *)(long)sem_post(&state->semaphore);
}

static int fail(int number, const char *message)
{
	printf("not ok %d %s\n", number, message);
	fflush(stdout);
	return 1;
}

int main(void)
{
	pthread_t thread;
	pthread_mutexattr_t attr;
	struct timespec deadline;
	void *result;
	int status;

	setvbuf(stdout, 0, _IONBF, 0);
	puts("TAP version 13\n1..4");
	state = mmap(0, 4096, PROT_READ | PROT_WRITE,
		     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (state == MAP_FAILED || (unsigned long)state < 0x1000000000UL ||
	    (unsigned long)state - 0x1000000000UL >= (1UL << 30))
		return fail(1, "synchronization objects must use an SVM VA");
	if (pthread_mutex_init(&state->mutex, 0) ||
	    pthread_mutex_lock(&state->mutex) ||
	    pthread_create(&thread, 0, mutex_worker, 0))
		return fail(1, "create contended mutex worker");
	while (!atomic_load(&state->entered))
		usleep(1000);
	usleep(10000);
	if (state->value || pthread_mutex_unlock(&state->mutex) ||
	    pthread_join(thread, &result) || result || state->value != 1)
		return fail(1, "contended mutex wake and handoff");
	puts("ok 1 contended mutex uses an SVM virtual address");

	if (pthread_cond_init(&state->condition, 0) ||
	    pthread_mutex_lock(&state->mutex) ||
	    pthread_create(&thread, 0, condition_worker, 0) ||
	    clock_gettime(CLOCK_REALTIME, &deadline))
		return fail(2, "prepare condition wait");
	deadline.tv_sec += 5;
	while (state->value != 42)
		if (pthread_cond_timedwait(&state->condition, &state->mutex,
					   &deadline))
			return fail(2, "condition wake with mutex reacquisition");
	if (pthread_mutex_unlock(&state->mutex) ||
	    pthread_join(thread, &result) || result)
		return fail(2, "join condition worker");
	puts("ok 2 condition wait wakes and reacquires an SVM mutex");

	if (pthread_mutexattr_init(&attr) ||
	    pthread_mutexattr_setrobust(&attr, PTHREAD_MUTEX_ROBUST) ||
	    pthread_mutex_init(&state->robust, &attr) ||
	    pthread_mutexattr_destroy(&attr) ||
	    pthread_create(&thread, 0, robust_worker, 0) ||
	    pthread_join(thread, &result) || result)
		return fail(3, "robust mutex owner exits");
	if (clock_gettime(CLOCK_REALTIME, &deadline))
		return fail(3, "read recovery deadline");
	deadline.tv_sec += 5;
	status = pthread_mutex_timedlock(&state->robust, &deadline);
	if (status != EOWNERDEAD) {
		printf("# robust lock returned %d, expected %d\n", status, EOWNERDEAD);
		return fail(3, "kernel marks the SVM robust owner dead");
	}
	if (pthread_mutex_consistent(&state->robust) ||
	    pthread_mutex_unlock(&state->robust) ||
	    pthread_mutex_destroy(&state->robust))
		return fail(3, "recover robust mutex");
	puts("ok 3 robust owner death and recovery traverse SVM pointers");

	if (sem_init(&state->semaphore, 0, 0) ||
	    pthread_create(&thread, 0, semaphore_worker, 0) ||
	    clock_gettime(CLOCK_REALTIME, &deadline))
		return fail(4, "prepare semaphore wait");
	deadline.tv_sec += 5;
	if (sem_timedwait(&state->semaphore, &deadline) ||
	    pthread_join(thread, &result) || result || state->value != 77 ||
	    sem_destroy(&state->semaphore) ||
	    pthread_cond_destroy(&state->condition) ||
	    pthread_mutex_destroy(&state->mutex) || munmap(state, 4096))
		return fail(4, "semaphore wake and synchronization cleanup");
	puts("ok 4 semaphore wakes a waiter through an SVM VA");
	if (getpid() == 1)
		reboot(RB_POWER_OFF);
	return 0;
}
