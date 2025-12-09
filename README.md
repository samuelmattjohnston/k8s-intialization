# Kubernetes Bootstrap (Debian 13 + Ambient Mesh)

This Ansible stack bootstraps a High-Availability Kubernetes Cluster on Debian 13 (Trixie).

It sets up a modern stack using **Cilium** for the CNI and **Istio Ambient Mesh** for L7 policy/mTLS. It’s designed to be flexible, handling both virtualized environments (discrete NICs) and bare-metal servers (VLAN trunking) via `systemd-networkd`.

## Architecture


## Stack Components

  * **OS:** Debian 13 (Trixie). Uses `systemd-networkd` exclusively (removes NetworkManager/ifupdown).
  * **HA Control Plane:** `kube-vip` provides a floating IP for the API server.
  * **CNI:** Cilium (with `kubeProxyReplacement=true`).
  * **Service Mesh:** Istio Ambient Mode.
      * **Ztunnel:** Rust-based DaemonSet for mTLS/L4 telemetry.
      * **Istio CNI:** Chains with Cilium to redirect traffic.
      * **Sidecar-less:** No Envoy sidecars injected into app pods.
  * **Ingress:** Kubernetes Gateway API + MetalLB (L2 Mode).

-----

## Networking Logic

This playbook uses a logic engine to calculate IPs and configure interfaces. You do not need to define every IP in the inventory; you just define the **Node ID** and the **Subnet Prefixes**.

### 1\. IP Calculation

The playbook combines `group_vars` prefixes with `inventory` IDs.

  * **Logic:** `network_prefix` + `node_id` = `Final IP`
  * **Example:**
      * Prefix: `192.168.255`
      * Node ID: `11`
      * **Result:** `192.168.255.11`

### 2\. Interface Modes

Set the `mode` variable in `inventory.ini` to tell the node how to handle the physical layer.

| Mode | Use Case | Logic |
| :--- | :--- | :--- |
| **standard** | VMs (Proxmox/ESXi) | Expects 4 discrete virtual NICs (`enX0`...`enX3`). The hypervisor handles tagging. |
| **trunk** | Bare Metal | Expects 1 physical cable (`trunk_parent`). Ansible creates `vlan.xx` interfaces on top of it. |

-----

## Configuration

### 1\. Nodes & Modes (`inventory.ini`)

Define your specific nodes here.

```ini
[masters]
# VM Example: Standard mode, Node ID 11
k8s-node-01 ansible_host=192.168.255.11 node_id=11 mode=standard

# Bare Metal Example: Trunk mode, Node ID 14, Physical cable is 'enp191s0'
k8s-node-04 ansible_host=192.168.255.14 node_id=14 mode=trunk trunk_parent=enp191s0
```

### 2\. Subnets & Versions (`group_vars/all.yml`)

The control center for the cluster.

```yaml
# Network Prefixes (The first 3 octets)
networks:
  admin:    { prefix: "192.168.255", cidr: "24" } # Control Plane
  public:   { prefix: "192.168.130", cidr: "24" } # Ingress / MetalLB
  private:  { prefix: "192.168.110", cidr: "24" } # East-West / Pods
  internal: { prefix: "192.168.100", cidr: "24" } # Storage

# VLAN Tags (Only used if mode=trunk)
vlan_ids:
  public: 130
  private: 110
  internal: 100

# Versions
versions:
  kubernetes: "1.34"
  cilium: "1.18.4"
  istio: "1.28.1"
```

### 3\. LoadBalancer Range

Edit `roles/k8s_addons/templates/metallb-config.yaml.j2` to set the IP range MetalLB can hand out.

```yaml
spec:
  addresses:
  - 192.168.130.50-192.168.130.60
```

-----

## Usage

**1. Clone**

```bash
git clone <repo>
cd k8s-initialization
```

**2. Run**

```bash
ansible-playbook -i inventory.ini site.yml
```

**3. Verify**
SSH into a master node:

```bash
# Check Node Status
kubectl get nodes -o wide

# Check Mesh Status (Ztunnel should be running on all nodes)
kubectl get ds -n istio-system ztunnel

# Check Gateway IP
kubectl get gateway -A
```

**4. Nuke / Reset**
If you need to start over, the `reset.yml` playbook runs a script that stops services, wipes etcd/k8s/cni directories, flushes iptables, and resets network interfaces.

```bash
ansible-playbook -i inventory.ini reset.yml
```

-----

## Notes

1.  **CNI Chaining:** Cilium installs first, then Istio CNI chains onto it. If you restart nodes, check `/etc/cni/net.d/` to ensure the configuration persists.
2.  **Gateway API:** The CRDs are installed from the standard upstream URL to ensure compatibility with Istio 1.28.
