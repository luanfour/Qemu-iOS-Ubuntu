# Qemu-ios-ubuntu

Aplicativo iOS nativo em **SwiftUI** (alvo **iOS 16+**) construído inteiramente com **Swift Package Manager (SwiftPM)** e **[xtool](https://github.com/xtool-org/xtool)** — **sem Xcode IDE** — para virtualizar **Ubuntu Server** no iPhone e iPad a partir de imagens `.iso` importadas pelo usuário e atuar como um servidor portátil de máquinas virtuais.

---

## Sumário

1. [Arquitetura e Funcionalidades](#arquitetura-e-funcionalidades)
2. [Estrutura de Pastas](#estrutura-de-pastas)
3. [Limitação de Desempenho sem JIT (TCI estilo UTM SE)](#limitação-de-desempenho-sem-jit-tci-estilo-utm-se)
4. [Como Habilitar JIT (StikDebug / SideStore / AltStore)](#como-habilitar-jit-stikdebug--sidestore--altstore)
5. [Como Integrar o `libqemu.xcframework` Pré-Compilado](#como-integrar-o-libqemuxcframework-pré-compilado)
6. [Instalação do `xtool` (Linux, macOS e Windows WSL2)](#instalação-do-xtool-linux-macos-e-windows-wsl2)
7. [Setup, Build e Execução (`xtool setup`, `xtool dev`)](#setup-build-e-execução-xtool-setup-xtool-dev)
8. [Assinatura com Apple ID Gratuito](#assinatura-com-apple-id-gratuito)
9. [Limitações: App Store vs. Sideload](#limitações-app-store-vs-sideload)
10. [Solução de Problemas](#solução-de-problemas)

---

## Arquitetura e Funcionalidades

O projeto segue o padrão MVVM + Serviços concorrentes (`@MainActor`, `async/await`, `Sendable`):

- **Importação de ISO (`UIDocumentPickerViewController`)**: copia imagens `.iso` do Ubuntu Server (`arm64` ou `x86_64`) para o sandbox (`Documents/ISOs/`), valida a assinatura ISO 9660 (`CD001`), calcula prefixo SHA-256 e detecta a arquitetura provável.
- **Gerenciador de VMs**: cria, edita, inicia, pausa, retoma, reinicia, para e exclui VMs. Configura vCPUs, RAM, disco virtual esparso **QCOW2 v3** gerado em Swift puro (`QCOW2ImageBuilder`), ISO anexada, ordem de boot (`dc`, `cd`, `d`, `c`, `n`), rede NAT (`user` mode com regras `hostfwd`, ex.: `2222 → 22`) e aceleração (`Auto`, `TCI`, `JIT`).
- **Camada de Abstração `QEMUBackend`**:
  - `EmbeddedQEMUBackend`: conecta-se via ponte C (`Sources/QEMUBridge`) ao `libqemu.xcframework` rodando em `pthread` dedicada com pilha de 8 MB, controle QMP por Unix Domain Socket (`stop`, `cont`, `system_powerdown`, `quit`, `savevm`) e console serial por TCP loopback.
  - `SimulatedQEMUBackend`: entra em ação automaticamente quando o binário `libqemu.xcframework` ainda não está linkado, permitindo testar toda a interface, console serial no SwiftTerm, geração de linha de comando QEMU, discos QCOW2, snapshots, modo servidor e cliente SSH imediatamente após compilar com `xtool dev`.
- **Terminal Serial Integrado (`SwiftTerm`)**: emulador VT100/Xterm conectado ao `-serial` da VM, com teclado completo do iOS, barra acessória (`Esc`, `Tab`, `Ctrl`, `Alt`, `Ctrl+C/D/L`, setas, `/`, `-`, `|`, `~`), histórico scrollback e copiar/colar.
- **Cliente SSH Integrado (`Citadel` / `SwiftNIO SSH`)**: abas múltiplas simultâneas, conexão rápida à VM local (`127.0.0.1:2222`) ou servidores remotos, autenticação por senha (salva no Keychain) ou chave **Ed25519**, e gerenciador completo de chaves (gerar `Curve25519`, importar OpenSSH PEM/Base64, copiar pública `ssh-ed25519`, exportar PEM).
- **Modo Servidor em Segundo Plano**: áudio PCM silencioso contínuo (`AVAudioSession` `.playback` + `.mixWithOthers`), `beginBackgroundTask`, `BGProcessingTask` e notificações locais (`UNUserNotificationCenter`) com status da VM, além de telemetria (gráficos de CPU/RAM, uptime, IP local `en0` e portas expostas).
- **Console Gráfico Opcional (VNC / SPICE)**: cliente RFB 3.8 nativo sobre `Network.framework` (`NWConnection`) para visualizar o framebuffer `-vnc` da VM e enviar eventos de toque/teclado, além de suporte a link externo `spice://`.
- **Armazenamento**: cálculo de espaço usado por discos QCOW2, ISOs, snapshots e pacotes exportados `.qemuvm`, além do espaço livre do dispositivo.
- **Interface Adaptativa**: `TabView` com `"Máquinas"`, `"Terminal"`, `"SSH"`, `"Configurações"`, suporte a tema Claro/Escuro/Sistema, `NavigationSplitView` no iPad e suporte à orientação horizontal.

---

## Estrutura de Pastas

```text
Qemu-iOS-Ubuntu/
├── Package.swift
├── xtool.yml
├── README.md
├── Config/
│   ├── Info.plist
│   ├── QemuIOSUbuntu.entitlements
│   └── QemuIOSUbuntu-Free.entitlements
├── Sources/
│   ├── QEMUBridge/
│   │   ├── include/QEMUBridge.h
│   │   └── QEMUBridge.c
│   └── QemuIOSUbuntu/
│       ├── App/
│       │   ├── AppEnvironment.swift
│       │   └── QemuIOSUbuntuApp.swift
│       ├── Models/
│       │   ├── AppError.swift
│       │   ├── ISOImage.swift
│       │   ├── SSHModels.swift
│       │   ├── SystemTelemetry.swift
│       │   ├── VMSnapshot.swift
│       │   └── VirtualMachine.swift
│       ├── Services/
│       │   ├── Background/BackgroundServerService.swift
│       │   ├── QEMU/
│       │   │   ├── EmbeddedQEMUBackend.swift
│       │   │   ├── JITDetector.swift
│       │   │   ├── QEMUBackend.swift
│       │   │   ├── QEMUService.swift
│       │   │   └── SimulatedQEMUBackend.swift
│       │   ├── SSH/
│       │   │   ├── KeychainHelper.swift
│       │   │   └── SSHService.swift
│       │   ├── Storage/
│       │   │   ├── QCOW2ImageBuilder.swift
│       │   │   └── StorageService.swift
│       │   ├── Terminal/TerminalService.swift
│       │   └── VNC/VNCClientService.swift
│       ├── ViewModels/
│       │   ├── SSHViewModel.swift
│       │   ├── SettingsStorageViewModel.swift
│       │   ├── TerminalViewModel.swift
│       │   └── VMManagerViewModel.swift
│       └── Views/
│           ├── MainTabView.swift
│           ├── Components/
│           │   ├── DocumentPickerView.swift
│           │   ├── ResourceSparklineView.swift
│           │   ├── ShareSheetView.swift
│           │   └── StatusBadgeView.swift
│           ├── Machines/
│           │   ├── MachinesListView.swift
│           │   ├── VMCardView.swift
│           │   ├── VMDetailView.swift
│           │   ├── VMEditorView.swift
│           │   └── VNCConsoleView.swift
│           ├── SSH/
│           │   ├── SSHHostEditorView.swift
│           │   ├── SSHKeyManagerView.swift
│           │   └── SSHTabView.swift
│           ├── Settings/
│           │   ├── SettingsTabView.swift
│           │   └── StorageManagerView.swift
│           └── Terminal/
│               ├── SwiftTermTerminalView.swift
│               ├── TerminalAccessoryBar.swift
│               └── TerminalTabView.swift
└── Tests/
    └── QemuIOSUbuntuTests/QemuIOSUbuntuTests.swift
```

---

## Limitação de Desempenho sem JIT (TCI estilo UTM SE)

O iOS aplica a política **W^X (Write XOR Execute)** no kernel Darwin: páginas de memória graváveis não podem ser marcadas como executáveis (`PROT_EXEC`) a menos que o processo possua a flag `CS_DEBUGGED` (ou o entitlement especial de JIT da Apple, indisponível para apps comuns).

Por padrão, o QEMU tradicional usa **TCG (Tiny Code Generator)** para traduzir blocos de instruções do guest (`aarch64` ou `x86_64`) em código de máquina nativo em tempo de execução — o que exige JIT e trava com `EXC_BAD_ACCESS` / `SIGBUS` em iPhones sem `CS_DEBUGGED`.

Para rodar sem JIT, utiliza-se a mesma abordagem do **UTM SE**:

1. Compilar o QEMU com **`--enable-tcg-interpreter` (TCI)**. No TCI, o TCG gera um bytecode intermediário interpretado em C puro (sem gerar código executável dinâmico).
2. **Impacto de desempenho**:
   - O modo TCI é aproximadamente **10x a 20x mais lento** do que o TCG com JIT nativo.
   - Um boot completo do Ubuntu Server em TCI pode levar de **3 a 10 minutos** na primeira inicialização (dependendo do chip A-series/M-series).
   - Recomendações práticas para Ubuntu Server sem JIT:
     - Prefira **Ubuntu Server `arm64` (`aarch64`)** ao invés de `x86_64`.
     - Use interface **100% headless** (`-nographic` / Console Serial + SSH) e desative VNC durante serviços contínuos.
     - Aloque **512 MB a 1024 MB de RAM** em dispositivos com 4 GB de RAM total para evitar encerramento pelo *Jetsam* do iOS.

O app verifica em tempo real via `csops(getpid(), CS_OPS_STATUS, ...)` em `Sources/QEMUBridge/QEMUBridge.c` se `CS_DEBUGGED (0x10000000)` está ativo e exibe o estado (`JIT Ativo` vs. `TCI sem JIT`) na aba **Configurações**.

---

## Como Habilitar JIT (StikDebug / SideStore / AltStore)

Quando o JIT é habilitado, o QEMU passa a usar tradução nativa multi-thread (`-accel tcg,thread=multi,tb-size=512`) e `-machine virt,highmem=on` + `-cpu max` no `aarch64`, tornando o Ubuntu Server dezenas de vezes mais rápido (ideal para o **iPhone 16 Pro / A18 Pro**):

### Opção 1: StikDebug (Recomendado no iPhone 16 Pro / iOS 17.4+)
O projeto já possui integração nativa com o **StikDebug** (`stikdebug://enable-jit?bundle-id=...` declarado em `LSApplicationQueriesSchemes` no `Config/Info.plist`):
1. Certifique-se de que a **LocalDevVPN** (ou VPN de loopback) e o **Pairing File** estejam ativos no **StikDebug**.
2. Instale o app assinado com perfil de desenvolvimento (`get-task-allow` ativo — o `xtool dev` e o SideStore já assinam assim por padrão).
3. Na aba **Máquinas** ou **Configurações** do **Qemu-ios-ubuntu**, toque em **Ativar JIT** (ou habilite **"Solicitar JIT (StikDebug) ao abrir o app"**).
4. O app abrirá o StikDebug automaticamente passando o `Bundle.main.bundleIdentifier` real em execução e, ao retornar, o selo mudará para **`JIT OK` / `Habilitado (StikDebug/Debugger)`**.

### Opção 2: SideStore / AltStore + StikJIT / AltJIT
1. Abra a aba **Meus Apps** no SideStore/AltStore, pressione longamente **Qemu-ios-ubuntu** e toque em **Enable JIT**.
2. Ao retornar ao app, toque em **Reverificar Capacidades JIT** na aba **Configurações**.

### Opção 3: JitStreamer / `pymobiledevice3` (Linux / WSL / macOS)
No iOS 17+, você pode anexar o depurador DDI via `pymobiledevice3`:
```bash
# Exemplo com pymobiledevice3 (requer tunneld ativo em outro terminal com sudo):
sudo python3 -m pymobiledevice3 remote tunneld
python3 -m pymobiledevice3 developer debugserver start-server
```
Ou utilizando uma instância do **JitStreamer-EB** na rede local com WireGuard.

---

## Como Integrar o `libqemu.xcframework` Pré-Compilado

Como o QEMU é uma base C/Meson extensa com dezenas de dependências (`glib`, `pixman`, `libffi`, `slirp`, `openssl`, `dtc`), ele é empacotado separadamente como um `XCFramework` (exatamente como faz o projeto `utmapp/UTM` com suas dependências pré-compiladas).

### Passo 1: Obter ou compilar o `libqemu.xcframework` para iOS (`arm64`)
Se você for compilar o QEMU a partir do código-fonte (ou extrair os binários estáticos de builds estilo UTM SE):

1. Compile as dependências estáticas para `aarch64-apple-ios` (`glib-2.0`, `pixman-1`, `libslirp`, `capstone`, `zstd`, `libffi`).
2. Configure o QEMU com TCI habilitado e ponto de entrada como biblioteca (`qemu_main` em vez de `main`):
   ```bash
   ./configure \
     --host=aarch64-apple-ios \
     --target-list=aarch64-softmmu,x86_64-softmmu \
     --enable-tcg-interpreter \
     --enable-slirp \
     --disable-cocoa \
     --disable-sdl \
     --disable-gtk \
     --disable-vnc-jpeg \
     --disable-docs \
     --static
   ```
3. Exponha o símbolo de entrada compatível com `QEMUBridge.c`:
   - `int qemu_system_aarch64_main(int argc, const char * const *argv);`
   - `int qemu_system_x86_64_main(int argc, const char * const *argv);`
   - (ou o símbolo genérico `qemu_main`).
4. Empacote as bibliotecas estáticas (`.a`) e headers em `Frameworks/libqemu.xcframework`:
   ```bash
   xcodebuild -create-xcframework \
     -library build-ios-arm64/libqemu-ios.a \
     -output Frameworks/libqemu.xcframework
   ```

### Passo 2: Declarar no `Package.swift`
Descomente/adicione o `.binaryTarget` no `Package.swift`:

```swift
targets: [
    .binaryTarget(
        name: "libqemu",
        path: "Frameworks/libqemu.xcframework"
    ),
    .target(
        name: "QEMUBridge",
        dependencies: ["libqemu"],
        ...
    )
]
```

Assim que o `libqemu.xcframework` estiver linkado, `qemu_bridge_is_libqemu_available("aarch64")` retornará `true` automaticamente via `dlsym(RTLD_DEFAULT, ...)` e o `QEMUService` usará o `EmbeddedQEMUBackend` real sem necessidade de alterar nenhum código Swift!

---

## Instalação do `xtool` (Linux, macOS e Windows WSL2)

O **[xtool](https://xtool.sh/)** permite compilar, assinar e instalar apps iOS via SwiftPM sem instalar o Xcode.

### Linux (Ubuntu / Debian x86_64 ou arm64)
1. Instale o **Swift Toolchain** (Swift 5.10 ou 6.0) seguindo [swift.org/install](https://www.swift.org/install/linux/) e as dependências USB:
   ```bash
   sudo apt update
   sudo apt install -y usbmuxd libimobiledevice6 libimobiledevice-utils curl unzip
   sudo systemctl enable --now usbmuxd
   ```
2. Baixe o release mais recente do `xtool` em [github.com/xtool-org/xtool/releases](https://github.com/xtool-org/xtool/releases) (AppImage ou tarball) e mova para `/usr/local/bin/xtool`:
   ```bash
   chmod +x xtool.AppImage
   sudo mv xtool.AppImage /usr/local/bin/xtool
   ```

### Windows (via WSL2 — Ubuntu)
1. Instale o WSL2 (`wsl --install -d Ubuntu-24.04`).
2. Dentro do Ubuntu no WSL2, siga exatamente os passos de **Linux** acima.
3. Para conectar o iPhone/iPad via USB dentro do WSL2, utilize **[usbipd-win](https://github.com/dorssel/usbipd-win)** no PowerShell do Windows (como Administrador):
   ```powershell
   winget install dorssel.usbipd-win
   usbipd list
   usbipd bind --busid <BUSID-DO-IPHONE>
   usbipd attach --wsl --busid <BUSID-DO-IPHONE>
   ```
4. No Ubuntu (WSL2), inicie o `usbmuxd`:
   ```bash
   sudo usbmuxd -f -v
   ```

### macOS
1. Instale o Swift (via Xcode Command Line Tools ou `swiftly`).
2. Instale o `xtool` via Homebrew ou release oficial:
   ```bash
   brew install xtool-org/tap/xtool
   ```

---

## Setup, Build e Execução (`xtool setup`, `xtool dev`)

### 1. Configurar o SDK do iOS (`xtool setup`)
O `xtool` precisa do iOS SDK extraído de um arquivo oficial `Xcode.xip` (baixado gratuitamente no portal Apple Developer):

```bash
xtool setup /caminho/para/Xcode_16.x.xip
```
Durante o setup, o `xtool` também solicitará login com seu **Apple ID** (para gerar certificados de desenvolvimento e perfis de provisionamento automaticamente).

### 2. Compilar e instalar no iPhone/iPad
Entre na pasta do projeto e execute:

```bash
cd Qemu-iOS-Ubuntu

# Apenas compilar o pacote e montar o bundle .app
xtool dev build

# Compilar, assinar, instalar e iniciar no iPhone/iPad conectado via USB
xtool dev run
# (Em versões recentes do xtool, `xtool dev` sem subcomando executa build + sign + install + run)
xtool dev
```

*(No macOS, também é possível testar a interface no simulador com `xtool dev --simulator`.)*

---

## Assinatura com Apple ID Gratuito

Este projeto já vem configurado em `xtool.yml` apontando para:
```yaml
entitlementsPath: Config/QemuIOSUbuntu-Free.entitlements
```

Com um **Apple ID gratuito**:
1. O `xtool` cria automaticamente um Team pessoal, gera o certificado de desenvolvimento e ajusta o `bundleID` (`com.luanquaresma.qemu-ios-ubuntu`) para evitar conflitos globais.
2. Após a primeira instalação no iPhone/iPad, vá em:
   **Ajustes → Geral → Gestão de VPN e Dispositivo → [Seu Apple ID] → Confiar**.
3. Para uso de depuração/JIT, ative também **Ajustes → Privacidade e Segurança → Modo de Desenvolvedor**.
4. Se você tiver uma **conta Apple Developer paga (\$99/ano)** e quiser liberar limites maiores de RAM (`increased-memory-limit` e `extended-virtual-addressing`), altere no `xtool.yml`:
   ```yaml
   entitlementsPath: Config/QemuIOSUbuntu.entitlements
   ```

---

## Limitações: App Store vs. Sideload

| Aspecto | App Store (Regras da Apple) | Sideload (`xtool` / AltStore / SideStore) |
| :--- | :--- | :--- |
| **Emuladores** | Permitido desde 2024 para consoles retro, mas VMs de SO desktop/Linux completos ainda sofrem escrutínio rigoroso | Totalmente livre para uso pessoal e desenvolvimento |
| **JIT (`CS_DEBUGGED`)** | Proibido para apps comuns; apenas TCI funciona | Possível habilitar via AltStore, SideStore, StikJIT ou JitStreamer |
| **Validade da Assinatura** | Permanente | **7 dias** em Apple ID gratuito (ou 1 ano em conta paga) |
| **Limite de RAM (Jetsam)** | Exige aprovação do entitlement `increased-memory-limit` | Conta gratuita fica limitada a ~1.5–2 GB antes de o iOS encerrar o app em 2º plano |
| **Execução em 2º Plano** | Áudio silencioso sem reprodução real pode ser rejeitado na revisão da App Store | Funciona normalmente via `AVAudioSession` para manter servidor SSH/Ubuntu ativo |

---

## Solução de Problemas

- **`xtool dev` não encontra o iPhone no Linux/WSL2**:
  - Verifique `idevice_id -l`. Se não listar nada, reinicie `sudo usbmuxd -f` e desbloqueie a tela do iPhone clicando em **Confiar neste computador**.
- **Erro de provisioning / entitlements ao assinar com Apple ID gratuito**:
  - Confirme que `xtool.yml` está usando `Config/QemuIOSUbuntu-Free.entitlements` (sem `increased-memory-limit`, que exige conta paga).
- **VM fecha sozinha ao usar muita RAM (Jetsam Kill)**:
  - Reduza a RAM da VM nas configurações para `512 MB` ou `768 MB` (suficiente para Ubuntu Server headless).
- **App suspenso após alguns minutos em segundo plano**:
  - Verifique na aba **Configurações** se **Manter servidor ativo em 2º plano** está ativado e se o **Áudio silencioso Keep-Alive** aparece como `Ativo` enquanto a VM roda. Em alguns cenários, o Modo Pouca Energia do iOS limita tarefas em background.
- **Conexão SSH para `127.0.0.1:2222` falha com "Connection refused"**:
  - Certifique-se de que a VM está no estado **Rodando**, que a regra NAT `host 2222 → guest 22` está ativa e que o `openssh-server` foi instalado/iniciado dentro do Ubuntu Server (`sudo apt install -y openssh-server && sudo systemctl enable --now ssh`).
- **Erro ao importar chave SSH privada**:
  - O importador nativo aceita chaves **OpenSSH Ed25519 sem passphrase** (`ssh-keygen -t ed25519 -N ""`). Se sua chave tiver senha, remova a passphrase antes de importar ou gere uma chave nova diretamente na aba **SSH → Chaves**.
