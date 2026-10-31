// Test-only, independent flock owner. No interpreter, AppKit, or inherited host loop.
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static void fail(const char *operation)
{
    fprintf(stderr, "NativeLeaseHolder: %s: %s\n", operation, strerror(errno));
    exit(1);
}

static double monotonic_now(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) fail("clock_gettime");
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static int exclusive_file(const char *path)
{
    int descriptor;
    do {
        descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    } while (descriptor < 0 && errno == EINTR);
    if (descriptor < 0) fail("create exclusive marker");
    return descriptor;
}

static void marker(const char *path)
{
    if (close(exclusive_file(path)) != 0) fail("close marker");
}

static void milestone(int descriptor, double started, const char *name)
{
    char message[128];
    int count = snprintf(message, sizeof(message), "%s elapsed=%.6fs\n", name, monotonic_now() - started);
    if (count < 0 || (size_t)count >= sizeof(message)) {
        errno = EOVERFLOW;
        fail("format milestone");
    }
    size_t written = 0;
    while (written < (size_t)count) {
        ssize_t result = write(descriptor, message + written, (size_t)count - written);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) fail("write milestone");
        written += (size_t)result;
    }
}

static void bootstrap_delay(double delay)
{
    double deadline = monotonic_now() + delay;
    for (;;) {
        double remaining = deadline - monotonic_now();
        if (remaining <= 0) return;
        struct timespec wait = {
            .tv_sec = (time_t)remaining,
            .tv_nsec = (long)((remaining - (double)(time_t)remaining) * 1000000000.0)
        };
        if (nanosleep(&wait, NULL) != 0 && errno != EINTR) fail("bootstrap delay");
    }
}

static char read_command(void)
{
    double deadline = monotonic_now() + 5.0;
    for (;;) {
        double remaining = deadline - monotonic_now();
        if (remaining <= 0) {
            fprintf(stderr, "NativeLeaseHolder: command deadline exceeded\n");
            exit(2);
        }
        struct pollfd input = { .fd = STDIN_FILENO, .events = POLLIN };
        int result = poll(&input, 1, (int)ceil(remaining * 1000.0));
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) fail("poll command");
        if (result == 0) continue;
        if (input.revents & (POLLERR | POLLNVAL)) {
            errno = EIO;
            fail("poll stdin state");
        }
        if (!(input.revents & (POLLIN | POLLHUP))) continue;
        char command;
        ssize_t count = read(STDIN_FILENO, &command, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) fail("read command");
        if (count == 0) {
            errno = EPIPE;
            fail("command channel closed");
        }
        return command;
    }
}

int main(int argc, char **argv)
{
    if (argc != 8) {
        fprintf(stderr, "usage: NativeLeaseHolder lease ready staged-index committed-index milestones bootstrap-ready delay\n");
        return 1;
    }
    char *end;
    errno = 0;
    double delay = strtod(argv[7], &end);
    if (errno || end == argv[7] || *end || !isfinite(delay) || delay < 0 || delay > 86400) {
        fprintf(stderr, "NativeLeaseHolder: invalid bootstrap delay\n");
        return 1;
    }
    double started = monotonic_now();
    int milestones = exclusive_file(argv[5]);
    milestone(milestones, started, "native-entered");
    bootstrap_delay(delay);
    milestone(milestones, started, "delay-complete");

    int lease;
    do {
        lease = open(argv[1], O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    } while (lease < 0 && errno == EINTR);
    if (lease < 0) fail("open lease");
    struct stat info;
    if (fstat(lease, &info) != 0) fail("inspect lease");
    if (!S_ISREG(info.st_mode)) {
        errno = EINVAL;
        fail("lease must be a regular file");
    }
    milestone(milestones, started, "lease-opened");
    marker(argv[6]);
    int locked;
    do {
        locked = flock(lease, LOCK_EX);
    } while (locked != 0 && errno == EINTR);
    if (locked != 0) fail("flock");
    milestone(milestones, started, "lease-acquired");
    marker(argv[2]);
    milestone(milestones, started, "ready-created");

    char command = read_command();
    if (command == 'C') {
        int committed;
        do {
            committed = rename(argv[3], argv[4]);
        } while (committed != 0 && errno == EINTR);
        if (committed != 0) fail("commit index");
    } else if (command != 'R') {
        errno = EINVAL;
        fail("unknown command");
    }
    if (close(lease) != 0) fail("close lease");
    if (close(milestones) != 0) fail("close milestones");
    return 0;
}
