#!/bin/bash

# Minikube + Cloudflare Tunnel Setup Script for CyberChief
# For macOS and Linux systems

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
    printf "${BLUE}[STEP]${NC} %s\n" "$1"
}

print_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

print_warning() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
}

print_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

# Function to check if command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "$1 is not installed or not in PATH"
        case "$1" in
            "docker")
                print_error "Install Docker from https://docs.docker.com/get-docker/"
                ;;
            "minikube")
                print_error "Install Minikube from https://minikube.sigs.k8s.io/docs/start/"
                ;;
            "cloudflared")
                print_error "Install Cloudflared from https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/"
                ;;
            "kubectl")
                print_error "Install kubectl from https://kubernetes.io/docs/tasks/tools/"
                ;;
        esac
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
        printf "Attempt %d/%d - API server not ready yet, waiting...\n" "$attempt" "$max_attempts"
        sleep 10
        ((attempt++))
    done
    
    print_error "API server failed to become ready after $max_attempts attempts"
    exit 1
}

# Function to get minikube API port
get_minikube_port() {
    local port=""
    
    # Method 1: Use minikube command (most reliable)
    if server_url=$(minikube kubectl -- config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null); then
        port=$(echo "$server_url" | grep -oE ':[0-9]+$' | cut -d':' -f2)
    fi
    
    # Method 2: Docker inspect (fallback)
    if [ -z "$port" ]; then
        port=$(docker inspect minikube --format='{{range $p, $conf := .NetworkSettings.Ports}}{{if eq $p "8443/tcp"}}{{range $conf}}{{.HostPort}}{{end}}{{end}}{{end}}' 2>/dev/null || echo "")
    fi
    
    # Method 3: Docker ps parsing (last resort)
    if [ -z "$port" ]; then
        port=$(docker ps --filter "name=minikube" --format "{{.Ports}}" --no-trunc | grep -oE '127\.0\.0\.1:[0-9]+->8443/tcp' | head -1 | cut -d':' -f2 | cut -d'-' -f1)
    fi
    
    # Clean and validate port
    port=$(echo "$port" | tr -d '[:space:]' | grep -oE '^[0-9]+$')
    
    if [ -z "$port" ] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
        print_error "Could not find valid Minikube API port"
        print_error "Debug information:"
        print_error "Minikube status:"
        minikube status || true
        print_error "Docker containers:"
        docker ps --filter "name=minikube" || true
        exit 1
    fi
    
    echo "$port"
}

# Function to start cloudflare tunnel
start_tunnel() {
    local port="$1"
    
    if [ -z "$port" ] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
        print_error "Invalid port provided: '$port'"
        exit 1
    fi
    
    print_step "Starting Cloudflare tunnel on port $port..."
    
    # Ensure directory exists
    mkdir -p "$(dirname "$TUNNEL_LOG_FILE")"
    
    # Start tunnel in background
    cloudflared tunnel --url "https://localhost:$port" --no-tls-verify > "$TUNNEL_LOG_FILE" 2>&1 &
    local tunnel_pid=$!
    
    # Save PID
    echo "$tunnel_pid" > "$TUNNEL_PID_FILE"
    
    print_step "Waiting for tunnel to establish..."
    local max_attempts=30
    local attempt=1
    local tunnel_url=""

    while [ $attempt -le $max_attempts ]; do
        if [ -f "$TUNNEL_LOG_FILE" ] && grep -q "trycloudflare.com" "$TUNNEL_LOG_FILE"; then
            tunnel_url=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$TUNNEL_LOG_FILE" | head -1)
            if [ -n "$tunnel_url" ]; then
                echo "$tunnel_url" > "$TUNNEL_URL_FILE"
                print_success "Tunnel established: $tunnel_url"
                return 0
            fi
        fi
        printf "Attempt %d/%d - Waiting for Cloudflare tunnel URL...\n" "$attempt" "$max_attempts"
        sleep 2
        ((attempt++))
    done

    print_error "Failed to extract tunnel URL after $max_attempts attempts"
    print_error "Tunnel log contents:"
    cat "$TUNNEL_LOG_FILE" 2>/dev/null || print_error "Could not read log file"
    kill "$tunnel_pid" 2>/dev/null || true
    exit 1
}

# Function to setup Trivy configuration
setup_trivy_config() {
    print_step "Setting up Trivy configuration..."
    
    if [ ! -f "k8s_trivy_setup.sh" ]; then
        print_warning "k8s_trivy_setup.sh not found in current directory"
        print_warning "This is optional - continuing with default service account"
        return 1
    fi
    
    chmod +x k8s_trivy_setup.sh
    print_step "Running k8s_trivy_setup.sh..."
    
    if ./k8s_trivy_setup.sh "$NAMESPACE"; then
        if [ -f "k8s_cluster_config.json" ]; then
            cp k8s_cluster_config.json /tmp/trivy_output.json
            print_success "Trivy setup completed"
            return 0
        fi
    fi
    
    print_warning "Trivy setup failed, continuing with default service account"
    return 1
}

# Function to extract JSON value
extract_json_value() {
    local json_file="$1"
    local key="$2"
    
    if command -v jq &> /dev/null; then
        jq -r ".$key" "$json_file" 2>/dev/null
    else
        # Fallback without jq
        grep "\"$key\"" "$json_file" | sed 's/.*"'$key'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1
    fi
}

# Function to create configuration
create_config() {
    local tunnel_url
    tunnel_url=$(cat "$TUNNEL_URL_FILE")
    
    print_step "Creating configuration for CyberChief..."
    
    local token=""
    if [ -f "/tmp/trivy_output.json" ]; then
        token=$(extract_json_value "/tmp/trivy_output.json" "token")
        print_step "Using Trivy service account token"
    else
        print_warning "Using default service account token"
        
        # Try to get token
        token=$(kubectl -n kube-system create token default 2>/dev/null || echo "")
        
        # Fallback for older Kubernetes versions
        if [ -z "$token" ]; then
            local secret_name
            secret_name=$(kubectl -n kube-system get serviceaccount default -o jsonpath='{.secrets[0].name}' 2>/dev/null || echo "")
            if [ -n "$secret_name" ]; then
                token=$(kubectl -n kube-system get secret "$secret_name" -o jsonpath='{.data.token}' | base64 --decode 2>/dev/null || echo "")
            fi
        fi
        
        if [ -z "$token" ]; then
            print_error "Could not retrieve service account token"
            exit 1
        fi
    fi
    
    cat > "$CONFIG_FILE" << EOF
{
  "cluster_name": "$CLUSTER_NAME",
  "server": "$tunnel_url",
  "namespace": "$NAMESPACE",
  "certificate_authority_data": "",
  "token": "$token"
}
EOF
    
    print_success "Configuration saved to $CONFIG_FILE"
}

# Optional Kubernetes Goat deployment
deploy_k8s_goat() {
    printf "Deploy Kubernetes Goat for testing? (y/N): "
    read -r deploy_goat
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
            print_warning "Git not found. Please install git to deploy Kubernetes Goat"
        fi
    fi
}

# Main execution
main() {
    echo -e "${GREEN}=== Minikube + Cloudflare Tunnel Setup for CyberChief ===${NC}"
    echo "Platform: $(uname -s) $(uname -m)"
    echo ""
    
    mkdir -p ./tmp
    
    # Check prerequisites
    print_step "Checking prerequisites..."
    check_command "docker"
    check_command "minikube"
    check_command "cloudflared"
    check_command "kubectl"
    
    if ! command -v jq &> /dev/null; then
        print_warning "jq not found - using fallback JSON parsing"
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
    
    # Get port and start tunnel
    print_step "Finding Minikube API port..."
    api_port=$(get_minikube_port)
    print_success "Found Minikube API port: $api_port"
    
    start_tunnel "$api_port"
    
    # Optional deployments and setup
    deploy_k8s_goat
    setup_trivy_config
    create_config
    
    # Summary
    echo ""
    echo -e "${GREEN}=== Setup Complete ===${NC}"
    echo "Tunnel URL: $(cat "$TUNNEL_URL_FILE")"
    echo "Configuration: $CONFIG_FILE"
    echo "Tunnel PID: $(cat "$TUNNEL_PID_FILE")"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Upload $CONFIG_FILE to CyberChief"
    echo "2. Run your scans"
    echo "3. When done: ./teardown-k8s-cyberchief.sh"
    echo ""
    echo -e "${BLUE}Tunnel is running in background${NC}"
}

# Cleanup on interrupt
cleanup() {
    print_warning "Cleaning up..."
    if [ -f "$TUNNEL_PID_FILE" ]; then
        kill "$(cat "$TUNNEL_PID_FILE")" 2>/dev/null || true
        rm -f "$TUNNEL_PID_FILE"
    fi
    exit 1
}

trap cleanup INT TERM
main "$@"