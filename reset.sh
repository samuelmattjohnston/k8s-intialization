#!/bin/bash
# ==========================================
# KUBERNETES "NUKE EVERYTHING" SCRIPT
# ==========================================

echo ">> Stopping Services..."
sudo systemctl stop kubelet
sudo systemctl disable kubelet
sudo systemctl stop containerd

echo ">> Killing lingering processes..."
# Combined list of processes from your multiple versions
sudo killall -9 kube-apiserver etcd kube-controller-manager kube-scheduler kube-proxy cilium-agent 2>/dev/null

echo ">> Resetting Kubeadm state..."
sudo kubeadm reset -f --cri-socket unix:///var/run/containerd/containerd.sock 2>/dev/null

echo ">> Wiping Filesystem..."
# Combined cleanup list
sudo rm -rf /etc/kubernetes/
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /var/lib/etcd/
sudo rm -rf /etc/cni/net.d/
sudo rm -rf /var/lib/cni/
sudo rm -rf /var/run/kubernetes/
sudo rm -rf /root/.kube/config
sudo rm -rf $HOME/.kube/config

echo ">> Pruning Containers (Nerdctl)..."
sudo systemctl start containerd
# Kill everything in k8s.io namespace
sudo nerdctl -n k8s.io ps -q -a | xargs -r sudo nerdctl -n k8s.io rm -f
# Prune volumes/images
sudo nerdctl -n k8s.io system prune -a --volumes -f

echo ">> Uninstalling Cilium CLI..."
cilium uninstall 2>/dev/null

echo ">> Flushing Network Interfaces..."
# Remove virtual interfaces so systemd-networkd recreates them
sudo ip link delete cilium_host 2>/dev/null
sudo ip link delete cilium_net 2>/dev/null
sudo ip link delete cilium_vxlan 2>/dev/null
sudo ip link delete kube-ipvs0 2>/dev/null
sudo ip link delete dummy0 2>/dev/null
# Remove VLAN interfaces created by Ansible
sudo ip link delete vlan.100 2>/dev/null
sudo ip link delete vlan.110 2>/dev/null
sudo ip link delete vlan.130 2>/dev/null

echo ">> Flushing IPTables..."
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

echo ">> Restarting Containerd..."
sudo systemctl restart containerd
sudo systemctl enable kubelet

echo ">> Reset Complete."
