/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <unistd.h>

static int pipefd[2];
static _Atomic int ready, cleaned, worker_tid, handled_tid;
static volatile int *observed;

static void cleanup(void *unused)
{
	(void)unused;
	atomic_store(&cleaned, 1);
}

static void *cancel_worker(void *unused)
{
	char byte;
	(void)unused;
	pthread_cleanup_push(cleanup, 0);
	atomic_store(&ready, 1);
	(void)read(pipefd[0], &byte, 1);
	pthread_cleanup_pop(0);
	return 0;
}

static void handle_signal(int number)
{
	(void)number;
	*observed = 17;
	atomic_store(&handled_tid, (int)syscall(SYS_gettid));
}

static void *signal_worker(void *unused)
{
	int tid = (int)syscall(SYS_gettid);
	(void)unused;
	atomic_store(&worker_tid, tid);
	while (atomic_load(&handled_tid) != tid)
		usleep(1000);
	return 0;
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
	void *result;
	struct sigaction action = {.sa_handler = handle_signal};

	puts("TAP version 13\n1..3");
	if (pipe(pipefd) || pthread_create(&thread, 0, cancel_worker, 0))
		return fail(1, "create cancellation worker");
	while (!atomic_load(&ready))
		usleep(1000);
	usleep(10000);
	if (pthread_cancel(thread) || pthread_join(thread, &result) ||
	    result != PTHREAD_CANCELED || !atomic_load(&cleaned))
		return fail(1, "deferred cancellation cleanup and join");
	close(pipefd[0]);
	close(pipefd[1]);
	puts("ok 1 deferred read cancellation runs cleanup and joins");
	observed = mmap(0, 4096, PROT_READ | PROT_WRITE,
			MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (observed == MAP_FAILED || (unsigned long)observed < 0x1000000000UL ||
	    (unsigned long)observed - 0x1000000000UL >= (1UL << 30))
		return fail(2, "signal target must be an SVM virtual mapping");
	sigemptyset(&action.sa_mask);
	if (sigaction(SIGUSR1, &action, 0) ||
	    pthread_kill(pthread_self(), SIGUSR1) || *observed != 17 ||
	    atomic_load(&handled_tid) != (int)syscall(SYS_gettid))
		return fail(2, "main signal handler writes an SVM mapping");
	puts("ok 2 main signal handler translates an SVM VA");
	*observed = 0;
	atomic_store(&handled_tid, 0);
	if (pthread_create(&thread, 0, signal_worker, 0))
		return fail(3, "create signal worker");
	while (!atomic_load(&worker_tid))
		usleep(1000);
	if (pthread_kill(thread, SIGUSR1) || pthread_join(thread, &result) ||
	    result || *observed != 17 ||
	    atomic_load(&handled_tid) != atomic_load(&worker_tid))
		return fail(3, "child signal handler uses its SVM TLS root");
	puts("ok 3 child signal handler uses its SVM TLS root");
	if (munmap((void *)observed, 4096))
		return 1;
	fflush(stdout);
	if (getpid() == 1)
		reboot(RB_POWER_OFF);
	return 0;
}
