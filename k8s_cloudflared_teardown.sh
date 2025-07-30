#!/bin/bash

# Minikube + Cloudflare Tunnel Teardown Script for CyberChief
# This script cleans up the setup created by k8s-cyberchief-setup.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
TUNNEL_PID_FILE="./tmp/cloudflared_tunnel.pid"
TUNNEL_URL_FILE="./tmp/cloudflared_tunnel_url.txt"
TUNNEL_LOG_FILE="./tmp/tunnel_output.log"
CONFIG_FILE="cyberchief_k8s_config.json"

# Function to print colored output
print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to stop cloudflare tunnel
stop_tunnel() {
    print_step "Stopping Cloudflare tunnel..."
    
    if [ -f "$TUNNEL_PID_FILE" ]; then
        local tunnel_pid=$(cat $TUNNEL_PID_FILE)
        if kill -0 $tunnel_pid 2>/dev/null; then
            kill $tunnel_pid
            print_success "Cloudflare tunnel stopped (PID: $tunnel_pid)"
        else
            print_warning "Tunnel process (PID: $tunnel_pid) was not running"
        fi
        rm -f $TUNNEL_PID_FILE
    else
        print_warning "No tunnel PID file found"
        
        # Try to find and kill any running cloudflared processes
        local cloudflared_pids=$(pgrep cloudflared 2>/dev/null || true)
        if [ ! -z "$cloudflared_pids" ]; then
            print_step "Found running cloudflared processes, attempting to stop them..."
            echo $cloudflared_pids | xargs kill 2>/dev/null || true
            print_success "Stopped cloudflared processes"
        fi
    fi
}

# Function to clean up Trivy RBAC resources
cleanup_trivy_rbac() {
    print_step "Checking for Trivy RBAC resources to clean up..."
    
    # Check if trivy-scanner service account exists
    if kubectl get serviceaccount trivy-scanner -n $NAMESPACE &>/dev/null; then
        read -p "Do you want to remove Trivy RBAC resources (service account, roles, etc.)? (y/N): " remove_trivy
        if [[ $remove_trivy =~ ^[Yy]$ ]]; then
            print_step "Removing Trivy RBAC resources..."
            
            # Remove the resources created by k8s_trivy_setup.sh
            kubectl delete serviceaccount trivy-scanner -n $NAMESPACE --ignore-not-found=true
            kubectl delete secret trivy-scanner-token -n $NAMESPACE --ignore-not-found=true
            kubectl delete clusterrole trivy-scanner-role --ignore-not-found=true
            kubectl delete clusterrolebinding trivy-scanner-rolebinding --ignore-not-found=true
            kubectl delete namespace trivy-temp --ignore-not-found=true
            
            # Remove the manifest file if it exists
            if [ -f "raider_manifest.yml" ]; then
                rm -f raider_manifest.yml
                echo "Removed: raider_manifest.yml"
            fi
            
            # Remove the original config file created by k8s_trivy_setup.sh
            if [ -f "k8s_cluster_config.json" ]; then
                rm -f k8s_cluster_config.json
                echo "Removed: k8s_cluster_config.json"
            fi
            
            print_success "Trivy RBAC resources removed"
        fi
    fi
}
# Function to clean up temporary files
cleanup_files() {
    print_step "Cleaning up temporary files..."
    rm -rf tmp
    print_success "Temporary files cleaned up"
}

# Function to remove Kubernetes Goat
remove_k8s_goat() {
    if kubectl get namespace kubernetes-goat &>/dev/null; then
        read -p "Do you want to remove Kubernetes Goat? (y/N): " remove_goat
        if [[ $remove_goat =~ ^[Yy]$ ]]; then
            print_step "Removing Kubernetes Goat..."
            
            # Try to use the official removal script if available
            if [ -f "kubernetes-goat/uninstall-kubernetes-goat.sh" ]; then
                cd kubernetes-goat
                bash uninstall-kubernetes-goat.sh
                cd ..
            else
                # Manual cleanup
                kubectl delete namespace kubernetes-goat --ignore-not-found=true
                kubectl delete clusterrolebinding kubernetes-goat --ignore-not-found=true
                kubectl delete clusterrole kubernetes-goat --ignore-not-found=true
            fi
            
            print_success "Kubernetes Goat removed"
        fi
    fi
}

# Function to stop/delete Minikube
handle_minikube() {
    if command -v minikube &> /dev/null; then
        if minikube status | grep -q "Running"; then
            echo -e "\n${YELLOW}Minikube Options:${NC}"
            echo "1. Stop Minikube (keep cluster for later use)"
            echo "2. Delete Minikube cluster (complete removal)"
            echo "3. Leave Minikube running"
            
            read -p "Choose option (1-3): " minikube_option
            
            case $minikube_option in
                1)
                    print_step "Stopping Minikube..."
                    minikube stop
                    print_success "Minikube stopped"
                    ;;
                2)
                    print_step "Deleting Minikube cluster..."
                    minikube delete
                    print_success "Minikube cluster deleted"
                    ;;
                3)
                    print_warning "Leaving Minikube running"
                    ;;
                *)
                    print_warning "Invalid option, leaving Minikube running"
                    ;;
            esac
        else
            print_warning "Minikube is not currently running"
        fi
    else
        print_warning "Minikube command not found"
    fi
}

# Function to handle configuration file
handle_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        read -p "Do you want to remove the configuration file ($CONFIG_FILE)? (y/N): " remove_config
        if [[ $remove_config =~ ^[Yy]$ ]]; then
            rm -f "$CONFIG_FILE"
            print_success "Configuration file removed"
        else
            print_warning "Configuration file preserved"
        fi
    fi
}

# Function to show cleanup summary
show_summary() {
    echo -e "\n${GREEN}=== Teardown Summary ===${NC}"
    echo -e "${GREEN}✓${NC} Cloudflare tunnel stopped"
    echo -e "${GREEN}✓${NC} Temporary files cleaned up"
    
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}!${NC} Configuration file preserved: $CONFIG_FILE"
    else
        echo -e "${GREEN}✓${NC} Configuration file removed"
    fi
    
    if command -v minikube &> /dev/null && minikube status | grep -q "Running"; then
        echo -e "${YELLOW}!${NC} Minikube cluster still running"
    else
        echo -e "${GREEN}✓${NC} Minikube cluster stopped/deleted"
    fi
}

# Function to force cleanup (for emergency situations)
force_cleanup() {
    print_warning "Performing force cleanup..."
    
    # Kill all cloudflared processes
    pkill -f cloudflared 2>/dev/null || true
    
    # Remove all temporary files
    rm -rf tmp
    
    # Stop minikube if running
    minikube stop 2>/dev/null || true
    
    print_success "Force cleanup completed"
}

# Main execution
main() {
    echo -e "${GREEN}=== Minikube + Cloudflare Tunnel Teardown ===${NC}"
    
    # Check if this is a force cleanup
    if [[ "$1" == "--force" || "$1" == "-f" ]]; then
        force_cleanup
        exit 0
    fi
    
    # Normal teardown process
    stop_tunnel
    cleanup_trivy_rbac
    cleanup_files
    remove_k8s_goat
    handle_config_file
    handle_minikube
    show_summary
    
    echo -e "\n${GREEN}Teardown completed successfully!${NC}"
    echo -e "${YELLOW}Tip:${NC} Use '$0 --force' for emergency cleanup"
}

# Show help
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --force, -f    Force cleanup (emergency mode)"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "This script cleans up the setup created by k8s-cyberchief-setup.sh"
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac











