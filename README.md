# kidds-cloudlab

Perfil do CloudLab e automação para avaliação de desempenho do **KIDDS** (Kernel-Integrated DDoS Defense System) em hardware físico com links de **100 Gbit/s**.

Esta topologia elimina emulações de software (como `veth` e dispositivos `TAP`), permitindo mensurar com precisão a latência sub-microssegundo e a taxa de transferência em linha (line-rate) do In-Kernel XDP e do AF_XDP Zero-Copy Busy-Polling.

---

## 1. Topologia de Rede (3 Nós Físicos)

```text
+-----------------------+                    +-------------------------+                    +-----------------------+
|        CLIENT         |                    |      KIDDS APPLIANCE    |                    |        SERVER         |
|  (Gerador & Atacante) | 100G Link 0        |    (Filtro / Scrubber)  | 100G Link 1        |   (Alvo Protegido)    |
|                       |------------------->| [dev-a]         [dev-b] |------------------->|                       |
|   10.10.1.1/24        |                    | 10.10.1.2     10.10.2.1 |                    |    10.10.2.2/24       |
+-----------------------+                    +-------------------------+                    +-----------------------+
```

| Nó | Tipo Padrão (CloudLab Clemson) | Função | Hardware |
|---|---|---|---|
| `client` (10.10.1.1) | `r6525` | Gerador de carga legítima (`wrk`, `wrk2`) e ataques (`slowhttptest`, `scapy`) | 2× AMD EPYC 7543 (64 núcleos), ConnectX-6 100G |
| `kidds` (10.10.1.2 & 10.10.2.1) | `r6525` ou `r6615` | Middlebox em ponte: executa In-Kernel XDP ou Daemon AF_XDP Zero-Copy | AMD EPYC, ConnectX-6 Dual-Port 100G |
| `server` (10.10.2.2) | `r6615` | Servidor Web de destino (Nginx de alta concorrência) | 1× AMD EPYC 9354P (32 núcleos), ConnectX-6 100G |

---

## 2. Como Usar no CloudLab

### Passo 1: Criar o Perfil no CloudLab
1. Crie um novo repositório público no GitHub com estes arquivos (ex: `https://github.com/ojoaosoares/kidds-cloudlab.git`).
2. Acesse o CloudLab: **Experiments → Create Experiment Profile → Git Repo**.
3. Cole a URL do repositório. O CloudLab lerá automaticamente o arquivo `profile.py`.

### Passo 2: Instanciar o Experimento
1. Clique em **Instantiate** no CloudLab e selecione o cluster **Clemson**.
2. Cada nó irá automaticamente:
   - Instalar o kernel HWE 24.04 (Linux 6.8+) e reiniciar uma vez;
   - Instalar `clang`, `libbpf`, `libxdp`, `llvm`, `nginx`, `wrk`, `wrk2` e `slowhttptest`;
   - Ajustar buffers do kernel, desativar `irqbalance` e configurar HugePages;
   - Criar o arquivo marcador `/local/setup-state/done` quando estiver pronto (cerca de 10 a 20 minutos).

### Passo 3: Executar o Bootstrap da sua Máquina Local
Na sua máquina de desenvolvimento (com acesso SSH ao CloudLab e com sua chave adicionada no `ssh-agent`):

```bash
eval "$(ssh-agent)" && ssh-add ~/.ssh/id_ed25519

# Uso: scripts/bootstrap.sh <kidds-host> <server-host> <client-host> [kidds-branch]
scripts/bootstrap.sh \
  clnode101.clemson.cloudlab.us \
  clnode102.clemson.cloudlab.us \
  clnode103.clemson.cloudlab.us \
  feat/slowloris-afxdp-stage1
```

O `bootstrap.sh`:
- Aguarda todos os nós finalizarem a inicialização;
- Clona o repositório privado do `KIDDS` via SSH agent forwarding (`ssh -A`);
- Compila o daemon AF_XDP (`bin/xsk_daemon`) e os módulos eBPF no nó `kidds`;
- Mapeia automaticamente as interfaces físicas de 100G e endereços MAC;
- Configura rotas estáticas e tabelas ARP para permitir o fluxo transparente `Client -> KIDDS -> Server`;
- Gera os arquivos `cloudlab.env`.

---

## 3. Executando os Benchmarks

Acesse o nó intermediário `kidds`:

```bash
ssh <usuario>@<kidds-host>
cd ~/KIDDS
source cloudlab.env
```

Execute o orquestrador comparativo automatizado:

```bash
~/kidds-cloudlab/scripts/run_cloudlab_benchmark.sh 30
```

O orquestrador executa em sequência:
1. **Baseline**: Encaminhamento nativo de kernel (sem filtro) sob ataque Slowloris.
2. **In-Kernel XDP**: Proteção em hardware/driver com eBPF XDP (Stage 1 + Stage 2).
3. **AF_XDP (Zero-Copy Busy-Polling)**: Proteção em userspace com driver nativo XSK e modelo ML (Decision Tree / Random Forest / Neural Network).

Ao término, gera tabela comparativa consolidada contendo:
- **Throughput HTTP (RPS)**
- **Latência HTTP (Média, p50, p99)**
- **Taxa de Erros e Timeouts**
- **Uso de CPU da máquina intermediária**
- **Latência de processamento por pacote (nanossegundos)**

---

## 4. Estrutura do Repositório

```text
kidds-cloudlab/
├── profile.py                     # Definição GENI RSpec para o CloudLab (3 nós, 2 links 100G)
├── setup/
│   └── node-setup.sh             # Script de provisionamento automático por papel (client, kidds, server)
├── scripts/
│   ├── bootstrap.sh              # Configuração inicial, mapeamento 100G e clonagem remota
│   └── run_cloudlab_benchmark.sh # Orquestrador da suíte de testes comparativos
└── README.md
```
