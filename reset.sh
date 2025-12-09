#!/bin/bash

# ==========================================
# KUBERNETES "NUKE EVERYTHING" SCRIPT
# ==========================================

# 1. Stop Services
# We stop the kubelet first to prevent it from restarting pods while we are deleting them.
echo ">> Stopping Kubelet and Containerd..."
sudo systemctl stop kubelet
sudo systemctl stop containerd

# 2. Kill Lingering Processes
# This ensures no zombie processes are holding locks on the Etcd database or network interfaces.
echo ">> Killing lingering processes..."
sudo killall -9 kube-apiserver etcd kube-controller-manager kube-scheduler kube-proxy cilium-agent 2>/dev/null

# 3. Reset Kubeadm
# This performs the official cleanup of the node.
echo ">> Resetting Kubeadm state..."
sudo kubeadm reset -f --cri-socket unix:///var/run/containerd/containerd.sock

# 4. Deep Clean Data Directories
echo ">> Wiping Data Directories..."
# Nuke Etcd data (Destroys the cluster database)
sudo rm -rf /var/lib/etcd
# Nuke K8s configs (admin.conf, controller manifests, etc)
sudo rm -rf /etc/kubernetes/
sudo rm -rf /var/lib/kubelet/
# Nuke CNI configs (Fixes the Cilium/Network confusion)
sudo rm -rf /etc/cni/net.d/
sudo rm -rf /var/lib/cni/
sudo rm -rf /var/run/kubernetes/

# 5. Clean User Config
# Removes the kubeconfig so you don't accidentally use old credentials.
echo ">> Removing local kubeconfig..."
rm -rf $HOME/.kube/config
# Also remove from root if you ran things as sudo
sudo rm -rf /root/.kube/config

# 6. Force Kill Containers
echo ">> Pruning Containers..."
sudo systemctl start containerd
# Kill all running containers in k8s.io namespace (where K8s lives)
sudo nerdctl -n k8s.io ps -q | xargs -r sudo nerdctl -n k8s.io rm -f
# Prune volumes and images to ensure fresh downloads
sudo nerdctl -n k8s.io system prune -a --volumes -f

# 7. Flush Network Interfaces
# This is required to fix the "Trunk" mode issue on Node 04.
# We remove all virtual interfaces so systemd-networkd can recreate them fresh.
echo ">> Flushing Network Interfaces..."
sudo ip link delete cilium_host 2>/dev/null
sudo ip link delete cilium_net 2>/dev/null
sudo ip link delete cilium_vxlan 2>/dev/null
# Remove VLAN interfaces created by Ansible
sudo ip link delete vlan.100 2>/dev/null
sudo ip link delete vlan.110 2>/dev/null
sudo ip link delete vlan.130 2>/dev/null

# 8. Flush IPTables
echo ">> Flushing IPTables..."
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# 9. Restart Services
echo ">> Restarting Container Runtime..."
sudo systemctl restart containerd
sudo systemctl enable kubelet

cilium uninstall
# 1. Reset kubeadm state
sudo kubeadm reset -f

# 2. Stop core services
sudo systemctl stop kubelet
sudo systemctl stop containerd

# 3. Aggressively remove ALL Kubernetes and Etcd data (including the failing certificate)
sudo rm -rf /etc/kubernetes/*
sudo rm -rf /var/lib/kubelet/*
sudo rm -rf /var/lib/etcd/*
sudo rm -rf /etc/cni/net.d/*
sudo rm /etc/kubernetes/admin.conf
# 4. Clean up all failed containers (using nerdctl)
CONTAINERS=$(sudo nerdctl --namespace k8s.io ps -q -a)
if [ ! -z "$CONTAINERS" ]; then
    sudo nerdctl --namespace k8s.io rm -f $CONTAINERS
fi

# 5. Restart container runtime and kubelet
sudo systemctl start containerd
sudo systemctl start kubelet

# 4. Flush Network Rules (Optional but recommended)
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

nerdctl system prune --namespace k8s.io --volumes -f



# 1. Stop Kubernetes Services
echo "Stopping Kubelet..."
sudo systemctl stop kubelet
sudo systemctl disable kubelet
sudo systemctl stop containerd

# 2. Kill all processes that might be holding ports
echo "Killing lingering processes..."
sudo killall -9 kube-apiserver etcd kube-controller-manager kube-scheduler kube-proxy cilium-agent 2>/dev/null

# 3. Force Kill Containers (The crucial step for your 8-hour old containers)
echo "Force removing K8s containers..."
sudo systemctl start containerd
# Kill everything in the k8s.io namespace
sudo nerdctl -n k8s.io ps -a -q | xargs -r sudo nerdctl -n k8s.io rm -f
# Prune the rest
sudo nerdctl -n k8s.io system prune -a --volumes -f

# 4. Deep Clean Directories
echo "Wiping Filesystem..."
sudo kubeadm reset -f --cri-socket unix:///var/run/containerd/containerd.sock 2>/dev/null
sudo rm -rf /etc/kubernetes/
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /var/lib/etcd/
sudo rm -rf /etc/cni/net.d/
sudo rm -rf /var/lib/cni/
sudo rm -rf /var/run/kubernetes/
sudo rm -rf /home/*/.kube

# 5. Flush Network
echo "Flushing Network..."
sudo ip link delete cilium_host 2>/dev/null
sudo ip link delete cilium_net 2>/dev/null
sudo ip link delete cilium_vxlan 2>/dev/null
sudo ip link delete kube-ipvs0 2>/dev/null
sudo ip link delete dummy0 2>/dev/null

# 6. Flush IPTables
echo "Flushing IPTables..."
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# 7. Restart Runtime
echo "Restarting Containerd..."
sudo systemctl restart containerd
sudo systemctl enable kubelet

echo "Reset Complete. Verify with 'nerdctl -n k8s.io ps' (should be empty)."
