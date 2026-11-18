#ifndef QEMU_BRIDGE_H
#define QEMU_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Ponteiro de função esperado caso libqemu.xcframework esteja linkado no processo.
/// Assinatura padrão adaptada do UTM SE / qemu_main(int argc, char **argv).
typedef int (*qemu_entry_fn)(int argc, const char * const *argv);

/// Verifica via csops(CS_OPS_STATUS) se o processo atual possui a flag CS_DEBUGGED
/// (ou seja, se JIT está habilitado via Xcode, AltStore, SideStore ou JitStreamer).
bool qemu_bridge_is_jit_enabled(void);

/// Verifica dinamicamente via dlsym se o símbolo do QEMU embarcado está disponível
/// no binário principal ou em frameworks carregados (`qemu_main` / `qemu_system_aarch64_main`).
bool qemu_bridge_is_libqemu_available(const char *arch);

/// Executa o ponto de entrada do QEMU embarcado em uma pthread dedicada,
/// retornando 0 se a inicialização assíncrona da thread foi bem-sucedida.
int qemu_bridge_launch_embedded(
    const char *arch,
    int argc,
    const char * const *argv,
    void (*on_exit_callback)(int exit_code, void *context),
    void *context
);

/// Retorna o endereço IP local da interface Wi-Fi (en0) ou nulo se indisponível.
/// O chamador deve liberar a string retornada com `free()`.
char *qemu_bridge_copy_local_ip_address(void);

#ifdef __cplusplus
}
#endif

#endif /* QEMU_BRIDGE_H */

