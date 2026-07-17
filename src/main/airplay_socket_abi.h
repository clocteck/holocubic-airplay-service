/* Author: sunfang1cn@gmail.com */

#ifndef AIRPLAY_SOCKET_ABI_H
#define AIRPLAY_SOCKET_ABI_H

#include <stddef.h>
#include <stdint.h>

#include "module_abi.h"

/* Optional SDK3 Socket ABI declarations documented by README_HOST_ABI.md. */
#define AIRPLAY_PROC_SOCKET_OPEN_V1        0x000F0001u
#define AIRPLAY_PROC_SOCKET_BIND_V1        0x000F0002u
#define AIRPLAY_PROC_SOCKET_LISTEN_V1      0x000F0003u
#define AIRPLAY_PROC_SOCKET_ACCEPT_V1      0x000F0004u
#define AIRPLAY_PROC_SOCKET_CONNECT_V1     0x000F0005u
#define AIRPLAY_PROC_SOCKET_RECV_V1        0x000F0006u
#define AIRPLAY_PROC_SOCKET_RECVFROM_V1    0x000F0007u
#define AIRPLAY_PROC_SOCKET_SEND_V1        0x000F0008u
#define AIRPLAY_PROC_SOCKET_SENDTO_V1      0x000F0009u
#define AIRPLAY_PROC_SOCKET_POLL_V1        0x000F000Au
#define AIRPLAY_PROC_SOCKET_SETSOCKOPT_V1  0x000F000Bu
#define AIRPLAY_PROC_SOCKET_GETSOCKNAME_V1 0x000F000Cu
#define AIRPLAY_PROC_SOCKET_SHUTDOWN_V1    0x000F000Du
#define AIRPLAY_PROC_SOCKET_CLOSE_V1       0x000F000Eu

typedef int32_t airplay_socket_handle_t;

#define AIRPLAY_SOCKET_INVALID ((airplay_socket_handle_t)-1)
#define AIRPLAY_SOCKET_TYPE_STREAM 1u
#define AIRPLAY_SOCKET_TYPE_DGRAM  2u

#define AIRPLAY_SOCKET_POLL_READ   (1u << 0)
#define AIRPLAY_SOCKET_POLL_WRITE  (1u << 1)
#define AIRPLAY_SOCKET_POLL_ERROR  (1u << 2)
#define AIRPLAY_SOCKET_POLL_HANGUP (1u << 3)

typedef struct airplay_socket_addr_t {
    uint32_t size;
    uint8_t address[4];
    uint16_t port;
    uint16_t reserved;
} airplay_socket_addr_t;

typedef struct airplay_socket_poll_item_t {
    uint32_t size;
    airplay_socket_handle_t socket;
    uint32_t events;
    uint32_t revents;
} airplay_socket_poll_item_t;

typedef struct airplay_socket_api_t {
    int32_t (*open)(uint32_t type, airplay_socket_handle_t *out_socket);
    int32_t (*bind)(airplay_socket_handle_t socket,
                    const airplay_socket_addr_t *local_addr);
    int32_t (*listen)(airplay_socket_handle_t socket, uint32_t backlog);
    int32_t (*accept)(airplay_socket_handle_t listener,
                      airplay_socket_handle_t *out_socket,
                      airplay_socket_addr_t *out_peer_addr);
    int32_t (*connect)(airplay_socket_handle_t socket,
                       const airplay_socket_addr_t *peer_addr);
    int32_t (*recv)(airplay_socket_handle_t socket, void *buf, size_t capacity,
                    size_t *out_received);
    int32_t (*recvfrom)(airplay_socket_handle_t socket, void *buf,
                        size_t capacity, size_t *out_received,
                        airplay_socket_addr_t *out_peer_addr);
    int32_t (*send)(airplay_socket_handle_t socket, const void *data,
                    size_t len, size_t *out_sent);
    int32_t (*sendto)(airplay_socket_handle_t socket, const void *data,
                      size_t len, const airplay_socket_addr_t *peer_addr,
                      size_t *out_sent);
    int32_t (*poll)(airplay_socket_poll_item_t *items, size_t count,
                    uint32_t timeout_ms, size_t *out_ready);
    int32_t (*setsockopt)(airplay_socket_handle_t socket, uint32_t option,
                          int32_t value);
    int32_t (*getsockname)(airplay_socket_handle_t socket,
                           airplay_socket_addr_t *out_local_addr);
    int32_t (*shutdown)(airplay_socket_handle_t socket, uint32_t how);
    int32_t (*close)(airplay_socket_handle_t socket);
} airplay_socket_api_t;

#endif
