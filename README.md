# Kubernetes Bootstrap (Debian 13 + Cilium + Istio Ambient)

This repository contains an automation stack designed to bootstrap a High-Availability Kubernetes Cluster on Debian 13. It deploys a purpose-built, "kube-proxy-free" networking architecture using **Cilium** as the CNI and **Istio Ambient Mesh** for Layer 7 policy.

The stack utilizes `systemd-networkd` to abstract the underlying hardware, allowing the same deployment logic to function on both virtualized environments and bare-metal servers.

## Architecture

The cluster avoids a flat network topology in favor of strict segmentation. Traffic is isolated across four configurable logical networks.



* **Admin Network:** Dedicated to out-of-band management and external API access. The **Admin VIP** resides here. To secure the control plane, **Cilium Network Policies** are automatically applied to block Pods from initiating connections to this subnet.
* **Public Network:** Dedicated to Ingress and Load Balancing. MetalLB binds exclusively to this network to handle ARP requests for external Services.
* **Private Network:** The **Cluster Backbone**. All Kubelet gossip, Etcd consensus traffic, and Cilium overlay packets flow here. The **Internal VIP** resides on this interface, ensuring the API server is always reachable by nodes even if the public network is saturated.
* **Internal Network:** Dedicated to bulk data transfer (Storage/NFS), typically configured with Jumbo Frames to offload IO from the control plane.

### Security and Reliability Features
* **Dual-VIP Strategy:** The cluster maintains two distinct Virtual IPs via `kube-vip`. One allows user access via the Admin network; the other maintains internal cluster consensus on the Private network.
* **Etcd Encryption:** The stack automatically generates encryption keys and configures the API server to encrypt all Secrets at rest (AES-GCM) before storing them in Etcd.
* **Maglev Load Balancing:** Cilium is configured to use the Maglev consistent hashing algorithm for service load balancing, providing higher reliability during node failures compared to random selection.

**Design Note on Tooling:** This stack intentionally avoids Helm for core infrastructure components. Helm charts often struggle with idempotency in complex, low-level networking setups, particularly when managing CNI chaining or critical DaemonSet patches. Native CLIs and raw upstream manifests are used to ensure transparency and prevent configuration drift.

## Constraints and Infrastructure Assumptions

For this automation to function correctly, the underlying infrastructure must meet specific networking criteria defined by the `mode` variable in the inventory.

* **Physical/Virtual Interface Count:** The automation expects to map four distinct logical networks.
    * **Standard Mode (VMs):** The VM must have four discrete network interfaces attached. The hypervisor is responsible for VLAN tagging upstream.
    * **Trunk Mode (Bare Metal):** The server must have a single physical uplink configured as a Trunk port on the switch. The automation will instantiate VLAN sub-interfaces on the host OS to match the required topology.
* **Operating System:** Target nodes must be running Debian 13 (Trixie).
* **Kernel Requirements:** The automation installs the **Zabbly Mainline Kernel**. This is a hard dependency as standard Debian kernels may lack specific eBPF features required by Cilium's advanced modes.

## Tuneable Levers

The stack is highly configurable via `group_vars/all.yml` and `inventory.ini`.

* **Subnet Prefixes:** Users define the network prefixes (e.g., /24 subnets) for all four networks. The automation calculates specific Node IPs based on a unique ID assigned to each host.
* **Interface Names:** The physical or virtual interface names (e.g., `ens18` or `eth0`) are configurable variables.
* **AI/GPU Tuning:** The stack includes specific GRUB and kernel parameter tuning (`ai_tuning_args`) optimized for AMD Strix Halo/AI workloads, which can be toggled per node group.
* **LoadBalancer Range:** Users define the start and end octets (e.g., 50-60). The automation appends these to the Public Network prefix to create the pool.
* **Component Versions:** All software versions (Kubernetes, Cilium, Istio, Kube-VIP) are pinned variables to ensure deterministic builds.

## Deployment Flow

The deployment follows a specific order of operations to resolve circular dependencies and network conflicts inherent in a multi-CNI stack.

### Dependency Installation and Normalization
The automation purges legacy networking tools (ifupdown, netplan) and configures `systemd-networkd`. It installs the Zabbly Kernel and applies critical Sysctl parameters (`fs.inotify`) to prevent file descriptor exhaustion in Envoy proxies. **Note:** The initial run will automatically reboot nodes to apply the new kernel and GRUB tuning parameters.

### Node-Pods (The Bootstrap VIP)
To initialize a High-Availability control plane, the API Server must bind to a Virtual IP (VIP). To resolve the circular dependency of running `kube-vip` (a Pod) before the API is up, the automation generates a **Static Pod Manifest** for `kube-vip`. This bootstrap VIP binds strictly to the **Private Network**, ensuring the control plane listens on the internal backbone immediately upon startup.

### Kubernetes Initialization
`kubeadm init` is executed with specific flags to support the "kube-proxy-free" architecture. The `--skip-phases=addon/kube-proxy` flag is used to prevent the installation of `kube-proxy`, as installing it alongside Cilium's eBPF replacement causes iptables rule conflicts. The control plane endpoint is explicitly set to the Private VIP.

### CNI Configuration (Cilium)
Cilium is installed as the primary network fabric.
* `routingMode=native`: Encapsulation is disabled for direct routing on the private network.
* `kubeProxyReplacement=true`: Enables eBPF service handling.
* `l2announcements.enabled=false`: Enforced to prevent Cilium from fighting with MetalLB over ARP requests on the Public Network.
After installation, a `CiliumNodeConfig` is applied to every node, forcing the overlay network to bind specifically to the Private Interface.

### Mesh Integration (Istio Ambient)
Istio is installed using **CNI Chaining**. It is deployed with `cni.chained=true`, instructing the Istio CNI agent to append itself to the existing Cilium configuration. To prevent race conditions on fresh reboots, the automation patches the Istio DaemonSet with an `initContainer` that waits for the Cilium configuration to exist before allowing Istio to start.

### Addons (Ingress)
MetalLB is deployed in Layer 2 mode with an `L2Advertisement` binding specifically to the Public Network interface. The Kubernetes Gateway API resources are then applied.

## Validation

The repository includes a comprehensive validation suite (`check_cluster.yml`) that verifies the functional and security requirements of the stack.

```bash
ansible-playbook -i inventory.ini check_cluster.yml
````

This playbook performs the following checks:

1.  **Infrastructure Health:** Verifies Node readiness and critical DaemonSets (Cilium, Ztunnel, MetalLB).
2.  **Gateway API:** Confirms the Istio Gateway has requested and received a Public IP.
3.  **Data Path:** Deploys a test application (`httpbin`) and validates traffic flow through the Ambient Mesh.
4.  **Security Isolation:** Performs a **negative connectivity test** by attempting to `curl` the Admin VIP from inside a Pod, ensuring Network Policies are correctly blocking access to the management plane.

## Reset and Cleanup

To facilitate rapid iteration, a "scorched earth" reset playbook is provided.

```bash
ansible-playbook -i inventory.ini reset.yml
```

This script drains nodes, stops Kubelet/Containerd, wipes all Kubernetes/CNI configurations, flushes `iptables`, and performs a hard reset of `systemd-networkd` to restore the clean networking state defined in the normalization phase.