#!/bin/bash
# Prepares the 3-node CloudLab environment for KIDDS benchmarks.
#
# Usage:
#   scripts/bootstrap.sh <kidds-host> <server-host> <client-host> [kidds-ref]
#
# Example:
#   scripts/bootstrap.sh clnode101.clemson.cloudlab.us clnode102.clemson.cloudlab.us clnode103.clemson.cloudlab.us feat/slowloris-afxdp-stage1

set -euo pipefail

KIDDS_HOST="${1:?kidds host required}"
SERVER_HOST="${2:?server host required}"
CLIENT_HOST="${3:?client host required}"
KIDDS_REF="${4:-feat/slowloris-afxdp-stage1}"
KIDDS_REPO="${KIDDS_REPO:-git@github.com:ojoaosoares/KIDDS.git}"
CL_USER="${CL_USER:-${USER}}"

IP_CLIENT="10.10.1.1"
IP_KIDDS_IN="10.10.1.2"
IP_KIDDS_OUT="10.10.2.1"
IP_SERVER="10.10.2.2"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

k() { ssh "${SSH_OPTS[@]}" "${CL_USER}@${KIDDS_HOST}" "$@"; }
ka() { ssh -A "${SSH_OPTS[@]}" "${CL_USER}@${KIDDS_HOST}" "$@"; }
s() { ssh "${SSH_OPTS[@]}" "${CL_USER}@${SERVER_HOST}" "$@"; }
c() { ssh "${SSH_OPTS[@]}" "${CL_USER}@${CLIENT_HOST}" "$@"; }
ca() { ssh -A "${SSH_OPTS[@]}" "${CL_USER}@${CLIENT_HOST}" "$@"; }

echo "=== Verificando ssh-agent local ==="
if ! ssh-add -l >/dev/null 2>&1; then
    echo "ERRO: Nenhuma chave carregada no ssh-agent. Execute:"
    echo '  eval "$(ssh-agent)" && ssh-add ~/.ssh/id_ed25519'
    exit 1
fi

echo "-> 1/6 Aguardando conclusao do setup em todos os 3 nós..."
for node in "${KIDDS_HOST}" "${SERVER_HOST}" "${CLIENT_HOST}"; do
    echo -n "   ${node}: "
    for i in $(seq 1 120); do
        if ssh "${SSH_OPTS[@]}" "${CL_USER}@${node}" test -e /local/setup-state/done 2>/dev/null; then
            kver=$(ssh "${SSH_OPTS[@]}" "${CL_USER}@${node}" uname -r)
            echo "pronto (Kernel ${kver})"
            break
        fi
        [ "${i}" = 120 ] && { echo "FALHA: timeout aguardando /local/setup-state/done"; exit 1; }
        sleep 15
    done
done

echo "-> 2/6 Clonando e compilando KIDDS no nó intermediario (kidds: ~/kidds)..."
ka "export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new'
    set -e
    [ -d ~/KIDDS/.git ] || git clone -q ${KIDDS_REPO} ~/KIDDS
    cd ~/KIDDS
    git fetch -q origin
    git checkout -q ${KIDDS_REF}
    git merge -q --ff-only origin/${KIDDS_REF} 2>/dev/null || true
    echo \"   Commit: \$(git log -1 --format='%h %s')\"
    make -j\$(nproc)
    make bin/xsk_daemon"
echo "   Compilacao do KIDDS concluida com sucesso."

echo "-> 3/6 Clonando suite de testes no nó cliente (client: ~/kidds)..."
ca "export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new'
    set -e
    [ -d ~/KIDDS/.git ] || git clone -q ${KIDDS_REPO} ~/KIDDS
    cd ~/KIDDS
    git fetch -q origin
    git checkout -q ${KIDDS_REF}
    git merge -q --ff-only origin/${KIDDS_REF} 2>/dev/null || true"
echo "   KIDDS sincronizado no nó cliente."

echo "-> 4/6 Identificando interfaces de rede e enderecos MAC..."
iface_of() { awk -v ip="$1" '$4 ~ "^"ip"/" { print $2; exit }'; }
mac_of() { awk '{print $1; exit}'; }

CIF=$(c ip -o -4 addr show | iface_of "${IP_CLIENT}")
KIF_IN=$(k ip -o -4 addr show | iface_of "${IP_KIDDS_IN}")
KIF_OUT=$(k ip -o -4 addr show | iface_of "${IP_KIDDS_OUT}")
SIF=$(s ip -o -4 addr show | iface_of "${IP_SERVER}")

echo "   Client Interface:     ${CIF} (${IP_CLIENT})"
echo "   KIDDS Ingress (dev-a): ${KIF_IN} (${IP_KIDDS_IN})"
echo "   KIDDS Egress (dev-b):  ${KIF_OUT} (${IP_KIDDS_OUT})"
echo "   Server Interface:     ${SIF} (${IP_SERVER})"

if [ -z "${CIF}" ] || [ -z "${KIF_IN}" ] || [ -z "${KIF_OUT}" ] || [ -z "${SIF}" ]; then
    echo "ERRO: Nao foi possivel localizar todas as interfaces 100G."
    exit 1
fi

CMAC=$(c cat "/sys/class/net/${CIF}/address")
KMAC_IN=$(k cat "/sys/class/net/${KIF_IN}/address")
KMAC_OUT=$(k cat "/sys/class/net/${KIF_OUT}/address")
SMAC=$(s cat "/sys/class/net/${SIF}/address")

echo "   Client MAC:     ${CMAC}"
echo "   KIDDS IN MAC:   ${KMAC_IN}"
echo "   KIDDS OUT MAC:  ${KMAC_OUT}"
echo "   Server MAC:     ${SMAC}"

echo "-> 5/6 Configurando roteamento e entradas ARP estaticas..."
# Client routes to Server via KIDDS
c "sudo ip route replace 10.10.2.0/24 via ${IP_KIDDS_IN} dev ${CIF}
   sudo arp -s ${IP_KIDDS_IN} ${KMAC_IN} || true"

# Server routes to Client via KIDDS
s "sudo ip route replace 10.10.1.0/24 via ${IP_KIDDS_OUT} dev ${SIF}
   sudo arp -s ${IP_KIDDS_OUT} ${KMAC_OUT} || true"

# KIDDS static ARPs for both ends
k "sudo arp -s ${IP_CLIENT} ${CMAC} || true
   sudo arp -s ${IP_SERVER} ${SMAC} || true
   sudo ethtool -L ${KIF_IN} combined 1 2>/dev/null || true
   sudo ethtool -L ${KIF_OUT} combined 1 2>/dev/null || true"

echo "-> 6/6 Gerando arquivos de ambiente cloudlab.env..."
k "cat > ~/KIDDS/cloudlab.env" <<EOF
# Gerado por kidds-cloudlab/scripts/bootstrap.sh em $(date -Is)
export ROLE=kidds
export DEV_A=${KIF_IN}
export DEV_B=${KIF_OUT}
export MAC_DEV_A=${KMAC_IN}
export MAC_DEV_B=${KMAC_OUT}
export PEER_A_IP=${IP_CLIENT}
export PEER_A_MAC=${CMAC}
export PEER_B_IP=${IP_SERVER}
export PEER_B_MAC=${SMAC}
export SERVER_IP=${IP_SERVER}
export CLIENT_IP=${IP_CLIENT}
EOF

c "cat > ~/KIDDS/cloudlab.env" <<EOF
# Gerado por kidds-cloudlab/scripts/bootstrap.sh em $(date -Is)
export ROLE=client
export CLIENT_DEV=${CIF}
export CLIENT_IP=${IP_CLIENT}
export SERVER_IP=${IP_SERVER}
export TARGET_URL=http://${IP_SERVER}:80/
EOF

cat <<EOF

======================================================================
Cluster KIDDS configurado com sucesso!
Topologia ativa:
  Client (${IP_CLIENT}) -> [${KIF_IN}] KIDDS [${KIF_OUT}] -> Server (${IP_SERVER})

Para iniciar os experimentos:
  1. No KIDDS:
     ssh ${CL_USER}@${KIDDS_HOST}
     cd ~/KIDDS && source cloudlab.env

  2. No Cliente:
     ssh ${CL_USER}@${CLIENT_HOST}
     cd ~/KIDDS && source cloudlab.env
======================================================================
EOF
