// Replaces src/detection/localip/localip_linux.c in the ESP32-S3 Linux build of fastfetch.
// The uClibc-ng on that board has no getifaddrs() (and no <ifaddrs.h>), which the original needs,
// so this lists the IPv4 addresses with SIOCGIFCONF instead. IPv6, MAC addresses, interface
// flags, MTU and link speed are not reported; the board's one network interface is a Wi-Fi
// station with an IPv4 address, and the 41-column console has no room for more anyway.
#include "localip.h"
#include "common/strutil.h"

#include <arpa/inet.h>
#include <net/if.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

const char* ffDetectLocalIps(const FFLocalIpOptions* options, FFlist* results) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        return "socket(AF_INET, SOCK_DGRAM) failed";
    }

    struct ifreq reqs[16];
    struct ifconf conf = { .ifc_len = (int) sizeof(reqs), .ifc_req = reqs };
    if (ioctl(fd, SIOCGIFCONF, &conf) < 0) {
        close(fd);
        return "ioctl(SIOCGIFCONF) failed";
    }

    int count = conf.ifc_len / (int) sizeof(struct ifreq);
    for (int i = 0; i < count; ++i) {
        const struct ifreq* req = &reqs[i];
        if (req->ifr_addr.sa_family != AF_INET) {
            continue;
        }

        struct ifreq query;
        memset(&query, 0, sizeof(query));
        memcpy(query.ifr_name, req->ifr_name, IFNAMSIZ - 1);
        if (ioctl(fd, SIOCGIFFLAGS, &query) < 0) {
            continue;
        }
        unsigned flags = (unsigned short) query.ifr_flags;
        if (!(flags & IFF_RUNNING)) {
            continue;
        }
        if ((flags & IFF_LOOPBACK) && !(options->showType & FF_LOCALIP_TYPE_LOOP_BIT)) {
            continue;
        }
        if (options->namePrefix.length && strncmp(req->ifr_name, options->namePrefix.chars, options->namePrefix.length) != 0) {
            continue;
        }

        char address[INET_ADDRSTRLEN + 16];
        inet_ntop(AF_INET, &((const struct sockaddr_in*) &req->ifr_addr)->sin_addr, address, INET_ADDRSTRLEN);

        if (options->showType & FF_LOCALIP_TYPE_PREFIX_LEN_BIT) {
            memset(&query, 0, sizeof(query));
            memcpy(query.ifr_name, req->ifr_name, IFNAMSIZ - 1);
            if (ioctl(fd, SIOCGIFNETMASK, &query) == 0) {
                int cidr = __builtin_popcount(((const struct sockaddr_in*) &query.ifr_netmask)->sin_addr.s_addr);
                if (cidr != 0) {
                    size_t len = strlen(address);
                    snprintf(address + len, 16, "/%d", cidr);
                }
            }
        }

        FFLocalIpResult* item = FF_LIST_ADD(FFLocalIpResult, *results);
        ffStrbufInitS(&item->name, req->ifr_name);
        ffStrbufInitS(&item->ipv4, address);
        ffStrbufInit(&item->ipv6);
        ffStrbufInit(&item->mac);
        ffStrbufInit(&item->flags);
        item->defaultRoute = FF_LOCALIP_TYPE_NONE;
        item->mtu = -1;
        item->speed = -1;
    }

    close(fd);
    return nullptr;
}
