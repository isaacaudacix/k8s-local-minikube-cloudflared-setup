#!/bin/bash

# Minikube + Cloudflare Tunnel Setup Script for CyberChief
# This script automates the setup process for exposing Minikube API via Cloudflare Tunnel

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="minikube"
NAMESPACE="default"
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

# Function to check if command exists
check_command() {
    if ! command -v $1 &> /dev/null; then
        print_error "$1 is not installed or not in PATH"
        exit 1
    fi
}

# Function to wait for API server to be ready
wait_for_api_server() {
    print_step "Waiting for Kubernetes API server to be ready..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if kubectl cluster-info &> /dev/null; then
            print_success "Kubernetes API server is ready"
            return 0
        fi
        echo "Attempt $attempt/$max_attempts - API server not ready yet, waiting..."
        sleep 10
        ((attempt++))
    done
    
    print_error "API server failed to become ready after $max_attempts attempts"
    exit 1
}

# Function to get minikube API port
get_minikube_port() {
    print_step "Finding Minikube API port..."
    local port=$(docker ps --filter "name=minikube" --format "table {{.Ports}}" | grep "8443/tcp" | head -1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\)->8443\/tcp.*/\1/p')
    
    if [ -z "$port" ]; then
        print_error "Could not find Minikube API port mapping"
        exit 1
    fi
    
    echo $port
}

# Function to start cloudflare tunnel
start_tunnel() {
    local port=$1
    print_step "Starting Cloudflare tunnel on port $port..."
    
    # Start tunnel in background and capture output
    cloudflared tunnel --url https://localhost:$port --no-tls-verify > $TUNNEL_LOG_FILE 2>&1 &
    local tunnel_pid=$!
    
    # Save PID for later cleanup
    echo $tunnel_pid > $TUNNEL_PID_FILE
    
    # Create Log File
    touch $TUNNEL_LOG_FILE

    # Wait for tunnel to establish and get URL
    print_step "Waiting for tunnel to establish and output URL..."
    local max_attempts=30
    local attempt=1
    local tunnel_url=""

    while [ $attempt -le $max_attempts ]; do
        if grep -q "trycloudflare.com" "$TUNNEL_LOG_FILE"; then
            tunnel_url=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TUNNEL_LOG_FILE" | head -1)
            if [ -n "$tunnel_url" ]; then
                echo "$tunnel_url" > "$TUNNEL_URL_FILE"
                print_success "Tunnel established: $tunnel_url"
                return 0
            fi
        fi
        echo "Attempt $attempt/$max_attempts - Waiting for Cloudflare tunnel URL..."
        sleep 2
        ((attempt++))
    done

    print_error "Failed to extract tunnel URL after $max_attempts attempts"
    kill $tunnel_pid 2>/dev/null || true
    exit 1
}

# Function to run k8s_trivy_setup.sh
setup_trivy_config() {
    print_step "Setting up Trivy configuration..."
    
    # Check if k8s_trivy_setup.sh exists
    if [ ! -f "k8s_trivy_setup.sh" ]; then
        print_warning "k8s_trivy_setup.sh not found in current directory"
        print_warning "Please download it from your workspace admin and place it in the current directory to continue"
        return 1
    fi
    
    # Make executable and run with the specified namespace
    chmod +x k8s_trivy_setup.sh
    print_step "Running k8s_trivy_setup.sh to create service account and RBAC..."
    
    if ./k8s_trivy_setup.sh "$NAMESPACE"; then
        # The script creates k8s_cluster_config.json, let's use that
        if [ -f "k8s_cluster_config.json" ]; then
            cp k8s_cluster_config.json /tmp/trivy_output.json
            print_success "Trivy setup completed - RBAC and service account created"
            print_success "Configuration saved to k8s_cluster_config.json"
            return 0
        else
            print_error "k8s_cluster_config.json was not created by k8s_trivy_setup.sh"
            return 1
        fi
    else
        print_error "Failed to run k8s_trivy_setup.sh"
        return 1
    fi
}

# Function to extract JSON value (fallback for systems without jq)
extract_json_value() {
    local json_file=$1
    local key=$2
    
    if command -v jq &> /dev/null; then
        jq -r ".$key" "$json_file"
    else
        # Fallback: use grep and sed for basic JSON parsing
        grep "\"$key\"" "$json_file" | sed 's/.*"'$key'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's/.*"'$key'"[[:space:]]*:[[:space:]]*\([^",}]*\).*/\1/'
    fi
}
# Function to create adjusted configuration
create_config() {
    local tunnel_url=$(cat $TUNNEL_URL_FILE)
    print_step "Creating adjusted configuration for CyberChief..."
    
    if [ -f "/tmp/trivy_output.json" ]; then
        # Use trivy output as base and adjust for Cloudflare tunnel
        local token=$(extract_json_value "/tmp/trivy_output.json" "token")
        
        print_step "Adjusting configuration for Cloudflare tunnel (clearing certificate_authority_data)..."
        cat > $CONFIG_FILE << EOF
{
  "cluster_name": "$CLUSTER_NAME",
  "server": "$tunnel_url",
  "namespace": "$NAMESPACE",
  "certificate_authority_data": "",
  "token": "$token"
}
EOF
    else
        # Fallback: create config manually using kubectl with default service account
        print_warning "Using fallback method to create configuration with default service account"
        print_warning "Note: This may have limited permissions compared to the Trivy service account"
        
        # Get service account token using kubectl
        local secret_name=$(kubectl -n kube-system get serviceaccount default -o jsonpath='{.secrets[0].name}' 2>/dev/null || echo "")
        local token=""
        
        if [ ! -z "$secret_name" ]; then
            token=$(kubectl -n kube-system get secret "$secret_name" -o jsonpath='{.data.token}' 2>/dev/null | base64 --decode 2>/dev/null || echo "")
        fi
        
        # Alternative method for newer Kubernetes versions
        if [ -z "$token" ]; then
            token=$(kubectl -n kube-system create token default 2>/dev/null || echo "")
        fi
        
        if [ -z "$token" ]; then
            print_error "Could not retrieve service account token"
            exit 1
        fi
        
        cat > $CONFIG_FILE << EOF
{
  "cluster_name": "$CLUSTER_NAME",
  "server": "$tunnel_url",
  "namespace": "$NAMESPACE",
  "certificate_authority_data": "",
  "token": "$token"
}
EOF
    fi
    
    print_success "Configuration saved to $CONFIG_FILE"
    print_step "Key adjustments made for Cloudflare tunnel:"
    echo "  - Server URL set to: $tunnel_url"
    echo "  - certificate_authority_data cleared (empty string)"
    echo "  - Token preserved from Trivy service account"
}

# Function to deploy Kubernetes Goat (optional)
deploy_k8s_goat() {
    read -p "Do you want to deploy Kubernetes Goat? (y/N): " deploy_goat
    if [[ $deploy_goat =~ ^[Yy]$ ]]; then
        print_step "Deploying Kubernetes Goat..."
        if command -v git &> /dev/null; then
            if [ ! -d "kubernetes-goat" ]; then
                git clone https://github.com/madhuakula/kubernetes-goat.git
            fi
            cd kubernetes-goat
            chmod +x setup-kubernetes-goat.sh
            bash setup-kubernetes-goat.sh
            cd ..
            print_success "Kubernetes Goat deployed"
        else
            print_warning "Git not found. Please manually deploy Kubernetes Goat following the official guide"
        fi
    fi
}

# Main execution
main() {
    echo -e "${GREEN}=== Minikube + Cloudflare Tunnel Setup for CyberChief ===${NC}"
    mkdir -p ./tmp
    
    # Check prerequisites
    print_step "Checking prerequisites..."
    check_command "docker"
    check_command "minikube"
    check_command "cloudflared"
    check_command "kubectl"
    # jq is optional - we'll use fallback methods if not available
    if ! command -v jq &> /dev/null; then
        print_warning "jq not found - using fallback JSON parsing methods"
    fi
    print_success "All prerequisites found"
    
    # Start Minikube
    print_step "Starting Minikube cluster..."
    if minikube status | grep -q "Running"; then
        print_warning "Minikube is already running"
    else
        minikube start
        print_success "Minikube started"
    fi
    
    # Wait for API server
    wait_for_api_server
    
    # Get Minikube port
    local api_port=$(get_minikube_port)
    print_success "Found Minikube API port: $api_port"
    
    # Start Cloudflare tunnel
    start_tunnel $api_port
    
    # Optional: Deploy Kubernetes Goat
    deploy_k8s_goat
    
    # Setup Trivy configuration
    setup_trivy_config
    
    # Create adjusted configuration
    create_config
    
    echo -e "\n${GREEN}=== Setup Complete ===${NC}"
    echo -e "Tunnel URL: $(cat $TUNNEL_URL_FILE)"
    echo -e "Configuration file: $CONFIG_FILE"
    echo -e "Tunnel PID: $(cat $TUNNEL_PID_FILE)"
    echo -e "\n${YELLOW}Next steps:${NC}"
    echo -e "1. Upload $CONFIG_FILE to CyberChief workspace"
    echo -e "2. Run scans from CyberChief"
    echo -e "3. When done, run the teardown script: ./k8s-cyberchief-teardown.sh"
    echo -e "\n${YELLOW}Note:${NC} The Cloudflare tunnel is running in the background"
}

# Cleanup function for interruptions
cleanup() {
    print_warning "Script interrupted, cleaning up..."
    if [ -f "$TUNNEL_PID_FILE" ]; then
        local tunnel_pid=$(cat $TUNNEL_PID_FILE)
        kill $tunnel_pid 2>/dev/null || true
        rm -f $TUNNEL_PID_FILE
    fi
    exit 1
}

# Set trap for cleanup
trap cleanup INT TERM

# Run main function
main "$@"











