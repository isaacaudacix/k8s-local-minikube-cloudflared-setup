@echo off
setlocal enabledelayedexpansion

:: Minikube + Cloudflare Tunnel Setup Script for CyberChief
:: For Windows systems

:: Configuration
set CLUSTER_NAME=minikube
set NAMESPACE=default
set TUNNEL_PID_FILE=.\tmp\cloudflared_tunnel.pid
set TUNNEL_URL_FILE=.\tmp\cloudflared_tunnel_url.txt
set TUNNEL_LOG_FILE=.\tmp\tunnel_output.log
set CONFIG_FILE=cyberchief_k8s_config.json

:: Create temp directory
if not exist ".\tmp" mkdir ".\tmp"

echo === Minikube + Cloudflare Tunnel Setup for CyberChief ===
echo Platform: Windows
echo.

:: Check prerequisites
echo [STEP] Checking prerequisites...

where docker >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Docker is not installed or not in PATH
    echo [ERROR] Install Docker Desktop from https://www.docker.com/products/docker-desktop
    exit /b 1
)

where minikube >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Minikube is not installed or not in PATH
    echo [ERROR] Install Minikube from https://minikube.sigs.k8s.io/docs/start/
    exit /b 1
)

where cloudflared >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Cloudflared is not installed or not in PATH
    echo [ERROR] Install from https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/
    exit /b 1
)

where kubectl >nul 2>&1
if errorlevel 1 (
    echo [ERROR] kubectl is not installed or not in PATH
    echo [ERROR] Install from https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/
    exit /b 1
)

echo [SUCCESS] All prerequisites found

:: Start Minikube
echo [STEP] Starting Minikube cluster...
minikube status | findstr "Running" >nul 2>&1
if errorlevel 1 (
    echo Starting Minikube...
    minikube start
    if errorlevel 1 (
        echo [ERROR] Failed to start Minikube
        exit /b 1
    )
    echo [SUCCESS] Minikube started
) else (
    echo [WARNING] Minikube is already running
)

:: Wait for API server
echo [STEP] Waiting for Kubernetes API server to be ready...
set /a attempt=1
set /a max_attempts=30

:wait_api_loop
kubectl cluster-info >nul 2>&1
if not errorlevel 1 (
    echo [SUCCESS] Kubernetes API server is ready
    goto api_ready
)

echo Attempt !attempt!/!max_attempts! - API server not ready yet, waiting...
timeout /t 10 /nobreak >nul
set /a attempt+=1
if !attempt! leq !max_attempts! goto wait_api_loop

echo [ERROR] API server failed to become ready after !max_attempts! attempts
exit /b 1

:api_ready

:: Get Minikube API port
echo [STEP] Finding Minikube API port...

:: Method 1: Use minikube command
for /f "tokens=*" %%i in ('minikube kubectl -- config view --minify -o jsonpath^="{.clusters[0].cluster.server}" 2^>nul') do set SERVER_URL=%%i
if defined SERVER_URL (
    for /f "tokens=2 delims=:" %%a in ("!SERVER_URL!") do set API_PORT=%%a
)

:: Method 2: Docker inspect (fallback)
if not defined API_PORT (
    for /f "tokens=*" %%i in ('docker inspect minikube --format^="{{range $p, $conf := .NetworkSettings.Ports}}{{if eq $p \"8443/tcp\"}}{{range $conf}}{{.HostPort}}{{end}}{{end}}{{end}}" 2^>nul') do set API_PORT=%%i
)

:: Method 3: Docker ps parsing (last resort)
if not defined API_PORT (
    for /f "tokens=*" %%i in ('docker ps --filter "name^=minikube" --format "{{.Ports}}" --no-trunc 2^>nul ^| findstr "8443/tcp"') do (
        for /f "tokens=2 delims=: " %%a in ("%%i") do (
            for /f "tokens=1 delims=-" %%b in ("%%a") do set API_PORT=%%b
        )
    )
)

:: Validate port
if not defined API_PORT (
    echo [ERROR] Could not find Minikube API port
    echo [ERROR] Debug information:
    minikube status
    docker ps --filter "name=minikube"
    exit /b 1
)

:: Clean port (remove any non-numeric characters)
for /f "tokens=* delims= " %%a in ("!API_PORT!") do set API_PORT=%%a
echo !API_PORT!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo [ERROR] Invalid port extracted: !API_PORT!
    exit /b 1
)

echo [SUCCESS] Found Minikube API port: !API_PORT!

:: Start Cloudflare tunnel
echo [STEP] Starting Cloudflare tunnel on port !API_PORT!...

:: Start tunnel in background
start /b "" cloudflared tunnel --url https://localhost:!API_PORT! --no-tls-verify > "!TUNNEL_LOG_FILE!" 2>&1

:: Get the PID (this is tricky in batch, we'll use a workaround)
timeout /t 2 /nobreak >nul

:: Wait for tunnel URL
echo [STEP] Waiting for tunnel to establish...
set /a attempt=1
set /a max_attempts=30

:wait_tunnel_loop
if exist "!TUNNEL_LOG_FILE!" (
    findstr "trycloudflare.com" "!TUNNEL_LOG_FILE!" >nul 2>&1
    if not errorlevel 1 (
        for /f "tokens=*" %%i in ('findstr "https://.*\.trycloudflare\.com" "!TUNNEL_LOG_FILE!"') do (
            set TUNNEL_LINE=%%i
            goto extract_url
        )
    )
)

echo Attempt !attempt!/!max_attempts! - Waiting for Cloudflare tunnel URL...
timeout /t 2 /nobreak >nul
set /a attempt+=1
if !attempt! leq !max_attempts! goto wait_tunnel_loop

echo [ERROR] Failed to extract tunnel URL after !max_attempts! attempts
if exist "!TUNNEL_LOG_FILE!" (
    echo [ERROR] Tunnel log contents:
    type "!TUNNEL_LOG_FILE!"
)
exit /b 1

:extract_url
:: Extract URL from the line (simplified approach)
for /f "tokens=*" %%i in ('findstr /r "https://[a-zA-Z0-9.-]*\.trycloudflare\.com" "!TUNNEL_LOG_FILE!"') do (
    set FULL_LINE=%%i
    for /f "tokens=*" %%j in ('echo !FULL_LINE! ^| findstr /o "https://"') do (
        set URL_PART=%%j
        for /f "tokens=2* delims=:" %%k in ("!URL_PART!") do (
            set TUNNEL_URL=https:%%k
            goto url_extracted
        )
    )
)

:url_extracted
:: Clean up the URL (remove any trailing characters)
for /f "tokens=1" %%i in ("!TUNNEL_URL!") do set TUNNEL_URL=%%i
echo !TUNNEL_URL! | findstr "trycloudflare.com" >nul
if errorlevel 1 (
    echo [ERROR] Could not extract valid tunnel URL
    exit /b 1
)

echo !TUNNEL_URL! > "!TUNNEL_URL_FILE!"
echo [SUCCESS] Tunnel established: !TUNNEL_URL!

:: Optional: Deploy Kubernetes Goat
set /p DEPLOY_GOAT="Deploy Kubernetes Goat for testing? (y/N): "
if /i "!DEPLOY_GOAT!"=="y" (
    echo [STEP] Deploying Kubernetes Goat...
    where git >nul 2>&1
    if not errorlevel 1 (
        if not exist "kubernetes-goat" (
            git clone https://github.com/madhuakula/kubernetes-goat.git
        )
        cd kubernetes-goat
        call setup-kubernetes-goat.sh
        cd ..
        echo [SUCCESS] Kubernetes Goat deployed
    ) else (
        echo [WARNING] Git not found. Please install git to deploy Kubernetes Goat
    )
)

:: Setup Trivy configuration (optional)
echo [STEP] Setting up Trivy configuration...
if exist "k8s_trivy_setup.sh" (
    echo [STEP] Running k8s_trivy_setup.sh...
    call k8s_trivy_setup.sh !NAMESPACE!
    if exist "k8s_cluster_config.json" (
        copy "k8s_cluster_config.json" "\tmp\trivy_output.json" >nul
        echo [SUCCESS] Trivy setup completed
        set TRIVY_SETUP=1
    ) else (
        echo [WARNING] Trivy setup failed, using default service account
        set TRIVY_SETUP=0
    )
) else (
    echo [WARNING] k8s_trivy_setup.sh not found - using default service account
    set TRIVY_SETUP=0
)

:: Create configuration
echo [STEP] Creating configuration for CyberChief...

:: Get service account token
if "!TRIVY_SETUP!"=="1" (
    echo [STEP] Using Trivy service account token
    :: Extract token from trivy output (simplified - assumes JSON is well-formed)
    for /f "tokens=*" %%i in ('findstr "token" "\tmp\trivy_output.json"') do (
        set TOKEN_LINE=%%i
        for /f "tokens=2 delims=:" %%j in ("!TOKEN_LINE!") do (
            set TOKEN=%%j
            :: Remove quotes and whitespace
            set TOKEN=!TOKEN:"=!
            set TOKEN=!TOKEN: =!
            set TOKEN=!TOKEN:,=!
        )
    )
) else (
    echo [WARNING] Using default service account token
    for /f "tokens=*" %%i in ('kubectl -n kube-system create token default 2^>nul') do set TOKEN=%%i
    
    :: Fallback for older Kubernetes versions
    if not defined TOKEN (
        for /f "tokens=*" %%i in ('kubectl -n kube-system get serviceaccount default -o jsonpath^="{.secrets[0].name}" 2^>nul') do set SECRET_NAME=%%i
        if defined SECRET_NAME (
            for /f "tokens=*" %%j in ('kubectl -n kube-system get secret "!SECRET_NAME!" -o jsonpath^="{.data.token}" 2^>nul') do (
                echo %%j > temp_token.txt
                certutil -decode temp_token.txt temp_decoded.txt >nul 2>&1
                set /p TOKEN=<temp_decoded.txt
                del temp_token.txt temp_decoded.txt >nul 2>&1
            )
        )
    )
)

if not defined TOKEN (
    echo [ERROR] Could not retrieve service account token
    exit /b 1
)

:: Create config JSON file
(
echo {
echo   "cluster_name": "!CLUSTER_NAME!",
echo   "server": "!TUNNEL_URL!",
echo   "namespace": "!NAMESPACE!",
echo   "certificate_authority_data": "",
echo   "token": "!TOKEN!"
echo }
) > "!CONFIG_FILE!"

echo [SUCCESS] Configuration saved to !CONFIG_FILE!

:: Summary
echo.
echo === Setup Complete ===
echo Tunnel URL: !TUNNEL_URL!
echo Configuration: !CONFIG_FILE!
echo.
echo Next steps:
echo 1. Upload !CONFIG_FILE! to CyberChief
echo 2. Run your scans
echo 3. When done: teardown-k8s-cyberchief.bat
echo.
echo Note: Tunnel is running in background

pause