#include "QEMUBridge.h"

#include <arpa/inet.h>
#include <dlfcn.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif

#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif

// Declaração da syscall privada do kernel Darwin para consultar flags de assinatura de código.
// Utilizada amplamente por emuladores iOS (UTM, DolphiniOS, PojavLauncher) para detectar JIT.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

typedef struct {
    qemu_entry_fn entry;
    int argc;
    char **argv;
    void (*on_exit_callback)(int exit_code, void *context);
    void *context;
} qemu_launch_payload_t;

bool qemu_bridge_is_jit_enabled(void) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & CS_DEBUGGED) != 0;
}

static qemu_entry_fn resolve_qemu_symbol(const char *arch) {
    if (arch != NULL && strcmp(arch, "x86_64") == 0) {
        void *sym = dlsym(RTLD_DEFAULT, "qemu_system_x86_64_main");
        if (sym != NULL) {
            return (qemu_entry_fn)sym;
        }
    } else if (arch != NULL && strcmp(arch, "aarch64") == 0) {
        void *sym = dlsym(RTLD_DEFAULT, "qemu_system_aarch64_main");
        if (sym != NULL) {
            return (qemu_entry_fn)sym;
        }
    }

    // Fallback para símbolo genérico `qemu_main`
    void *generic_sym = dlsym(RTLD_DEFAULT, "qemu_main");
    if (generic_sym != NULL) {
        return (qemu_entry_fn)generic_sym;
    }
    return NULL;
}

bool qemu_bridge_is_libqemu_available(const char *arch) {
    return resolve_qemu_symbol(arch) != NULL;
}

static void *qemu_thread_runner(void *raw_payload) {
    qemu_launch_payload_t *payload = (qemu_launch_payload_t *)raw_payload;
    int code = payload->entry(payload->argc, (const char * const *)payload->argv);

    if (payload->on_exit_callback != NULL) {
        payload->on_exit_callback(code, payload->context);
    }

    for (int i = 0; i < payload->argc; i++) {
        free(payload->argv[i]);
    }
    free(payload->argv);
    free(payload);
    return NULL;
}

int qemu_bridge_launch_embedded(
    const char *arch,
    int argc,
    const char * const *argv,
    void (*on_exit_callback)(int exit_code, void *context),
    void *context
) {
    qemu_entry_fn entry = resolve_qemu_symbol(arch);
    if (entry == NULL || argc <= 0 || argv == NULL) {
        return -1;
    }

    qemu_launch_payload_t *payload = calloc(1, sizeof(qemu_launch_payload_t));
    if (payload == NULL) {
        return -2;
    }

    payload->entry = entry;
    payload->argc = argc;
    payload->on_exit_callback = on_exit_callback;
    payload->context = context;
    payload->argv = calloc((size_t)(argc + 1), sizeof(char *));
    if (payload->argv == NULL) {
        free(payload);
        return -2;
    }

    for (int i = 0; i < argc; i++) {
        payload->argv[i] = strdup(argv[i] != NULL ? argv[i] : "");
        if (payload->argv[i] == NULL) {
            for (int j = 0; j < i; j++) {
                free(payload->argv[j]);
            }
            free(payload->argv);
            free(payload);
            return -2;
        }
    }

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    // Pilha de 8 MB recomendada para o interpretador TCG/TCI no iOS
    pthread_attr_setstacksize(&attr, 8 * 1024 * 1024);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);

    pthread_t thread;
    int result = pthread_create(&thread, &attr, qemu_thread_runner, payload);
    pthread_attr_destroy(&attr);

    if (result != 0) {
        for (int i = 0; i < argc; i++) {
            free(payload->argv[i]);
        }
        free(payload->argv);
        free(payload);
        return result;
    }

    return 0;
}

char *qemu_bridge_copy_local_ip_address(void) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0 || interfaces == NULL) {
        return NULL;
    }

    char *found_ip = NULL;
    for (struct ifaddrs *cursor = interfaces; cursor != NULL; cursor = cursor->ifa_next) {
        if (cursor->ifa_addr == NULL) {
            continue;
        }
        if ((cursor->ifa_flags & IFF_UP) == 0 || (cursor->ifa_flags & IFF_LOOPBACK) != 0) {
            continue;
        }
        if (cursor->ifa_addr->sa_family == AF_INET && cursor->ifa_name != NULL) {
            if (strcmp(cursor->ifa_name, "en0") == 0 || strcmp(cursor->ifa_name, "pdp_ip0") == 0) {
                struct sockaddr_in *addr = (struct sockaddr_in *)cursor->ifa_addr;
                char buffer[INET_ADDRSTRLEN] = {0};
                if (inet_ntop(AF_INET, &addr->sin_addr, buffer, sizeof(buffer)) != NULL) {
                    found_ip = strdup(buffer);
                    if (strcmp(cursor->ifa_name, "en0") == 0) {
                        break; // Prioriza interface Wi-Fi
                    }
                }
            }
        }
    }

    freeifaddrs(interfaces);
    return found_ip;
}

