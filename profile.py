"""KIDDS benchmark: 3-node topology with an inline inspection appliance.

Topology:
  [client] (10.10.1.1) <--- 100G Link 0 ---> [kidds] <--- 100G Link 1 ---> [server] (10.10.2.2)
                                   (10.10.1.2)      (10.10.2.1)

Roles:
  - client: generates legitimate traffic (wrk, wrk2, curl) and DDoS/Slowloris attacks.
  - kidds: inline security middlebox running In-Kernel XDP and AF_XDP Zero-Copy daemons.
  - server: protected target running high-performance Nginx.

All nodes boot Ubuntu 24.04, upgrade to the HWE kernel, and execute node-setup.sh.
Once setup finishes, /local/setup-state/done is created on all nodes.
"""

import geni.portal as portal
import geni.rspec.pg as pg
import geni.rspec.emulab as emulab  # noqa: F401

pc = portal.Context()

pc.defineParameter("kiddsType", "KIDDS Middlebox hardware type",
                   portal.ParameterType.NODETYPE, "r6525",
                   longDescription="Hardware type for KIDDS intermediary appliance. "
                   "r6525 (Clemson) has dual-port ConnectX-6 100G NICs and 64 cores.")
pc.defineParameter("clientType", "Client / Generator hardware type",
                   portal.ParameterType.NODETYPE, "r6525",
                   longDescription="Hardware type for load/attack generator. "
                   "r6525: 64 cores AMD EPYC 7543, ConnectX-6 100G.")
pc.defineParameter("serverType", "Server hardware type",
                   portal.ParameterType.NODETYPE, "r6615",
                   longDescription="Hardware type for protected backend server. "
                   "r6615: single-socket 32 cores AMD EPYC 9354P, ConnectX-6 100G.")
pc.defineParameter("linkSpeed", "Link speed (Kbps)",
                   portal.ParameterType.INTEGER, 100000000,
                   longDescription="100000000 = 100 Gbit/s.")
pc.defineParameter("sameSwitch", "Keep all nodes on one switch",
                   portal.ParameterType.BOOLEAN, False,
                   longDescription="Minimizes latency and jitter. Uncheck if cluster lacks free nodes.")
pc.defineParameter("image", "Disk image",
                   portal.ParameterType.IMAGE,
                   "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU24-64-STD",
                   advanced=True)

params = pc.bindParameters()
request = pc.makeRequestRSpec()


def create_node(name, hw_type, role):
    node = request.RawPC(name)
    node.hardware_type = hw_type
    node.disk_image = params.image
    node.addService(pg.Execute(
        shell="bash",
        command="sudo nohup bash /local/repository/setup/node-setup.sh %s >/dev/null 2>&1 &" % role
    ))
    return node


# 1. Instantiate 3 Nodes
node_client = create_node("client", params.clientType, "client")
node_kidds  = create_node("kidds",  params.kiddsType,  "kidds")
node_server = create_node("server", params.serverType, "server")

# 2. Configure Interfaces
iface_client_out = node_client.addInterface("if0")
iface_client_out.addAddress(pg.IPv4Address("10.10.1.1", "255.255.255.0"))

iface_kidds = node_kidds.addInterface("if0")
iface_kidds.addAddress(pg.IPv4Address("10.10.1.2", "255.255.255.0"))
iface_kidds.addAddress(pg.IPv4Address("10.10.2.1", "255.255.255.0"))

iface_server_in = node_server.addInterface("if0")
iface_server_in.addAddress(pg.IPv4Address("10.10.2.2", "255.255.255.0"))

# 3. Create shared LAN
lan = request.LAN("shared_lan")
lan.bandwidth = int(params.linkSpeed)
lan.setNoBandwidthShaping()
lan.addInterface(iface_client_out)
lan.addInterface(iface_kidds)
lan.addInterface(iface_server_in)
if params.sameSwitch:
    lan.setNoInterSwitchLinks()
pc.printRequestRSpec(request)
