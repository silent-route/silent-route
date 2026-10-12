// nettest — phase 0 experiment helper for Silent Route.
//
// Answers one question: does macOS pf match outgoing TCP and UDP packets by the
// owning socket's group (`pass out ... group N`)? If it does, the kill switch
// can say "only sing-box may write to the physical interface" instead of
// duplicating the routing rules as address lists.
//
// The process changes its credentials first (must start as root), then sends
// one probe out of the given interface, bypassing the routing table with
// IP_BOUND_IF — the same way sing-box's direct outbound leaves the machine
// while a TUN owns the default route.
//
//   nettest [--uid N] [--gid N] [--supp N] probe tcp|udp-conn|udp-unconn IP PORT IFACE
//   nettest [--uid N] [--gid N] [--supp N] exec CMD [ARGS...]
//
// Prints OK, BLOCKED (timeout) or ERR <reason>. Exit code 0 only for OK.

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

static const int TIMEOUT_SEC = 3;

// A DNS query for "example.com A". Any recursive resolver answers it, so a reply
// proves the packet left and came back.
static const unsigned char QUERY[] = {
    0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00, 0x00, 0x01, 0x00, 0x01,
};

static int wait_fd(int fd, int for_write) {
    fd_set set;
    FD_ZERO(&set);
    FD_SET(fd, &set);
    struct timeval tv = {TIMEOUT_SEC, 0};
    return select(fd + 1, for_write ? NULL : &set, for_write ? &set : NULL, NULL, &tv);
}

static int bind_iface(int fd, const char *iface) {
    unsigned idx = if_nametoindex(iface);
    if (idx == 0) {
        printf("ERR no interface %s\n", iface);
        return -1;
    }
    if (setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, sizeof idx) != 0) {
        printf("ERR IP_BOUND_IF: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

static int probe(const char *mode, const char *ip, int port, const char *iface) {
    struct sockaddr_in dst = {.sin_len = sizeof dst, .sin_family = AF_INET, .sin_port = htons(port)};
    if (inet_pton(AF_INET, ip, &dst.sin_addr) != 1) {
        printf("ERR bad address %s\n", ip);
        return 2;
    }
    int tcp = strcmp(mode, "tcp") == 0;
    int fd = socket(AF_INET, tcp ? SOCK_STREAM : SOCK_DGRAM, 0);
    if (fd < 0 || bind_iface(fd, iface) != 0) return 2;

    if (tcp) {
        fcntl(fd, F_SETFL, O_NONBLOCK);
        if (connect(fd, (struct sockaddr *)&dst, sizeof dst) != 0 && errno != EINPROGRESS) {
            printf("ERR connect: %s\n", strerror(errno));
            return 2;
        }
        if (wait_fd(fd, 1) <= 0) { puts("BLOCKED"); return 1; }
        int err = 0;
        socklen_t len = sizeof err;
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
        if (err) { printf("ERR connect: %s\n", strerror(err)); return 2; }
        puts("OK");
        return 0;
    }

    ssize_t sent;
    if (strcmp(mode, "udp-conn") == 0) {
        // Connected socket: what Go's net.Dial("udp") gives sing-box's DNS client.
        if (connect(fd, (struct sockaddr *)&dst, sizeof dst) != 0) {
            printf("ERR connect: %s\n", strerror(errno));
            return 2;
        }
        sent = send(fd, QUERY, sizeof QUERY, 0);
    } else if (strcmp(mode, "udp-unconn") == 0) {
        // Unconnected socket + sendto: what quic-go (hysteria2) does.
        sent = sendto(fd, QUERY, sizeof QUERY, 0, (struct sockaddr *)&dst, sizeof dst);
    } else {
        printf("ERR unknown mode %s\n", mode);
        return 2;
    }
    if (sent < 0) {
        // pf with block-policy drop silently drops; an error here would be a
        // different mechanism and is reported as such.
        printf("ERR send: %s\n", strerror(errno));
        return 2;
    }
    if (wait_fd(fd, 0) <= 0) { puts("BLOCKED"); return 1; }
    unsigned char buf[512];
    if (recv(fd, buf, sizeof buf, 0) <= 0) { printf("ERR recv: %s\n", strerror(errno)); return 2; }
    puts("OK");
    return 0;
}

int main(int argc, char **argv) {
    long uid = -1, gid = -1, supp = -1;
    int i = 1;
    for (; i + 1 < argc && strncmp(argv[i], "--", 2) == 0; i += 2) {
        long v = strtol(argv[i + 1], NULL, 10);
        if (strcmp(argv[i], "--uid") == 0) uid = v;
        else if (strcmp(argv[i], "--gid") == 0) gid = v;
        else if (strcmp(argv[i], "--supp") == 0) supp = v;
        else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
    }
    if (i >= argc) { fprintf(stderr, "usage: see the comment at the top of nettest.c\n"); return 2; }

    // Order matters: groups first, uid last, or we lose the right to change them.
    if (gid >= 0) {
        gid_t groups[2] = {(gid_t)gid, (gid_t)(supp >= 0 ? supp : gid)};
        if (setgroups(supp >= 0 ? 2 : 1, groups) != 0 || setgid((gid_t)gid) != 0) {
            printf("ERR setgid: %s\n", strerror(errno));
            return 2;
        }
    } else if (supp >= 0) {
        gid_t groups[2] = {getgid(), (gid_t)supp};
        if (setgroups(2, groups) != 0) { printf("ERR setgroups: %s\n", strerror(errno)); return 2; }
    }
    if (uid >= 0 && setuid((uid_t)uid) != 0) {
        printf("ERR setuid: %s\n", strerror(errno));
        return 2;
    }

    if (strcmp(argv[i], "exec") == 0 && i + 1 < argc) {
        execvp(argv[i + 1], &argv[i + 1]);
        printf("ERR exec: %s\n", strerror(errno));
        return 2;
    }
    if (strcmp(argv[i], "probe") == 0 && i + 4 < argc)
        return probe(argv[i + 1], argv[i + 2], atoi(argv[i + 3]), argv[i + 4]);
    fprintf(stderr, "usage: see the comment at the top of nettest.c\n");
    return 2;
}
