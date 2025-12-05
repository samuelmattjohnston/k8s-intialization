Here is the professional, text-only version of the documentation, suitable for corporate or strict engineering environments.

-----

# Production Kubernetes on Debian 13 (Ambient Mesh Edition)

This Ansible stack provisions a High-Availability Kubernetes Cluster from scratch on Debian 13 (Trixie).

It implements a modern, "sidecar-less" service mesh architecture using Cilium for CNI networking and Istio Ambient Mesh for L7 policy and mTLS. It is designed for both virtualized environments (discrete NICs) and bare-metal servers (VLAN trunking).

## End Result Architecture

Upon completion, the stack will consist of the following components:

  * **OS Layer:** Debian 13 with `systemd-networkd`. NetworkManager and ifupdown are disabled or removed.
  * **Control Plane HA:** `kube-vip` providing a floating IP for the API server.
  * **CNI Layer:** Cilium (pinned version) replacing kube-proxy (`kubeProxyReplacement=true`).
  * **Service Mesh:** Istio Ambient Mode.
      * Uses **Ztunnel** (Rust-based DaemonSet) for mTLS and L4 telemetry.
      * Uses **Istio CNI** to redirect traffic to Ztunnel.
      * No sidecars injected into application pods.
  * **Ingress/LoadBalancer:**
      * **Gateway API** (standard Kubernetes Gateway resources).
      * **MetalLB** (Layer 2 mode) providing public IPs to the Istio Ingress Gateway.

## Requirements

**Control Machine**

  * Ansible 2.10+
  * SSH access to target nodes.

**Target Nodes**

  * **OS:** Debian 13 (Trixie) Minimal Install.
  * **Privileges:** User with `sudo` access (passwordless preferred).
  * **Hardware:**
      * Masters: 2 vCPU, 4GB RAM minimum.
      * Workers: Dependent on workload.

**Networking**
The stack assumes 4 logical networks (though they can be flattened if configured):

1.  **Admin:** Kubernetes Control Plane traffic (API Server).
2.  **Public:** Ingress traffic (MetalLB / North-South).
3.  **Private:** East-West pod traffic (Cilium VXLAN/Geneve).
4.  **Internal:** Storage/Maintenance traffic.

## Assumptions & Networking Logic

This playbook uses a logic engine (`roles/networking/tasks/normalize.yml`) to detect how to configure the node based on the `mode` variable defined in the inventory.

### Mode A: `standard` (VMs)

  * Assumes the host has discrete virtual NICs for every network.
  * **Logic:** Maps `enX0` -\> Admin, `enX1` -\> Public, etc.
  * **Use Case:** Proxmox/VMware VMs where the hypervisor handles VLAN tagging.

### Mode B: `trunk` (Bare Metal)

  * Assumes the host has **one physical cable** (`trunk_parent`) carrying tagged traffic.
  * **Logic:** Ansible creates `vlan.20`, `vlan.30`, etc., on top of the parent interface using `systemd-networkd`.
  * **Use Case:** Physical servers connected to switch ports set to "Trunk".

## Configuration Levers

The stack can be customized by modifying the following files.

### 1\. Cluster Topology (`inventory.ini`)

Define your nodes and their specific networking mode here.

| Variable | Description |
| :--- | :--- |
| `mode` | `standard` or `trunk`. Determines network setup strategy. |
| `trunk_parent` | **Required if mode=trunk**. The physical interface name (e.g., `eno1`, `eth0`). |
| `*_ip` | Set the static IP for `admin`, `public`, `private`, and `internal` subnets. |

**Example:**

```ini
[masters]
# VM Example
node-01 ansible_host=192.168.1.10 mode=standard

# Bare Metal Example
node-02 ansible_host=192.168.1.11 mode=trunk trunk_parent=eno1
```

### 2\. Global Versions & Subnets (`group_vars/all.yml`)

This file acts as the control center for the cluster. **Pin your versions here.**

| Variable | Default | Description |
| :--- | :--- | :--- |
| `versions.kubernetes` | `1.34` | The major.minor version for the Apt repository. |
| `versions.cilium` | `1.18.4` | The version of the Cilium CNI agent. |
| `versions.istio` | `1.28.1` | The version of Istiod and Ztunnel. |
| `vlan_ids.*` | `20, 30, 40` | The VLAN Tags used if a node is in `trunk` mode. |
| `cluster_vip` | `...50` | The Floating IP for the Kubernetes API (handled by Kube-VIP). |

### 3\. MetalLB Address Pool (`roles/k8s_addons/templates/metallb-config.yaml.j2`)

Define the range of IP addresses that MetalLB is allowed to assign to LoadBalancer services.

```yaml
spec:
  addresses:
  - 192.168.130.51-192.168.130.60  # <--- Update this range
```

### 4\. Istio Profile (`roles/k8s_addons/templates/istio-config.yaml.j2`)

The `ambient` profile is used by default. To revert to sidecars or standard mode, change the profile here.

```yaml
spec:
  profile: ambient  # Change to 'default' or 'minimal' if needed
```

## Usage

**1. Clone and Prepare**

```bash
git clone <repo_url>
cd k8s-initialization
```

**2. Configure Inventory**
Edit `inventory.ini` to match your IP scheme and node types.

**3. Run the Playbook**

```bash
ansible-playbook -i inventory.ini site.yml
```

**4. Verify Installation**
SSH into the master node and run:

```bash
# 1. Check Nodes
kubectl get nodes -o wide

# 2. Check Cilium & Network Health
cilium status

# 3. Check Ztunnel (Ambient Mesh Data Plane)
kubectl get ds -n istio-system ztunnel

# 4. Check Gateway IP Assignment
kubectl get svc -n istio-system -l istio.io/gateway-name=main-gateway
```

## Considerations 

1.  **Systemd-Networkd Exclusive:** This playbook explicitly relies on `systemd-networkd`. It does not configure `/etc/network/interfaces`. Ensure the base OS image does not have conflicting configurations.
2.  **CNI Chaining:** The playbook installs Cilium first, then chains Istio CNI on top. If nodes are restarted, verify `/etc/cni/net.d/` contains `istio-cni` in the plugin list.
3.  **Gateway API:** Gateway API CRDs are installed via URL to ensure compatibility with the decoupled release cycle of Istio.
