@echo off
setlocal enabledelayedexpansion

:: Minikube + Cloudflare Tunnel Teardown Script for CyberChief
:: This script cleans up the setup created by setup-k8s-cyberchief.bat

:: Configuration
set TUNNEL_PID_FILE=.\tmp\cloudflared_tunnel.pid
set TUNNEL_URL_FILE=.\tmp\cloudflared_tunnel_url.txt
set TUNNEL_LOG_FILE=.\tmp\tunnel_output.log
set CONFIG_FILE=cyberchief_k8s_config.json
set NAMESPACE=default

:: Check for command line arguments
if "%1"=="--force" goto force_cleanup
if "%1"=="-f" goto force_cleanup
if "%1"=="--help" goto show_help
if "%1"=="-h" goto show_help

echo === Minikube + Cloudflare Tunnel Teardown ===
echo.

:: Stop Cloudflare tunnel
echo [STEP] Stopping Cloudflare tunnel...

:: Try to kill cloudflared processes
taskkill /f /im cloudflared.exe >nul 2>&1
if not errorlevel 1 (
    echo [SUCCESS] Cloudflare tunnel stopped
) else (
    echo [WARNING] No cloudflared processes found or could not stop them
)

:: Remove PID file if it exists
if exist "!TUNNEL_PID_FILE!" (
    del "!TUNNEL_PID_FILE!"
    echo Removed tunnel PID file
)

:: Check for Trivy RBAC resources
echo [STEP] Checking for Trivy RBAC resources...
kubectl get serviceaccount trivy-scanner -n !NAMESPACE! >nul 2>&1
if not errorlevel 1 (
    set /p REMOVE_TRIVY="Remove Trivy RBAC resources (service account, roles, etc.)? (y/N): "
    if /i "!REMOVE_TRIVY!"=="y" (
        echo [STEP] Removing Trivy RBAC resources...
        
        kubectl delete serviceaccount trivy-scanner -n !NAMESPACE! --ignore-not-found=true >nul 2>&1
        kubectl delete secret trivy-scanner-token -n !NAMESPACE! --ignore-not-found=true >nul 2>&1
        kubectl delete clusterrole trivy-scanner-role --ignore-not-found=true >nul 2>&1
        kubectl delete clusterrolebinding trivy-scanner-rolebinding --ignore-not-found=true >nul 2>&1
        kubectl delete namespace trivy-temp --ignore-not-found=true >nul 2>&1
        
        :: Remove manifest files if they exist
        if exist "raider_manifest.yml" (
            del "raider_manifest.yml"
            echo Removed: raider_manifest.yml
        )
        
        if exist "k8s_cluster_config.json" (
            del "k8s_cluster_config.json"
            echo Removed: k8s_cluster_config.json
        )
        
        echo [SUCCESS] Trivy RBAC resources removed
    )
)

:: Clean up temporary files
echo [STEP] Cleaning up temporary files...
if exist "tmp" (
    rmdir /s /q "tmp" >nul 2>&1
    echo [SUCCESS] Temporary files cleaned up
)

:: Check for Kubernetes Goat
echo [STEP] Checking for Kubernetes Goat...
kubectl get namespace kubernetes-goat >nul 2>&1
if not errorlevel 1 (
    set /p REMOVE_GOAT="Remove Kubernetes Goat? (y/N): "
    if /i "!REMOVE_GOAT!"=="y" (
        echo [STEP] Removing Kubernetes Goat...
        
        :: Try to use official removal script if available
        if exist "kubernetes-goat\uninstall-kubernetes-goat.sh" (
            cd kubernetes-goat
            call uninstall-kubernetes-goat.sh
            cd ..
        ) else (
            :: Manual cleanup
            kubectl delete namespace kubernetes-goat --ignore-not-found=true >nul 2>&1
            kubectl delete clusterrolebinding kubernetes-goat --ignore-not-found=true >nul 2>&1
            kubectl delete clusterrole kubernetes-goat --ignore-not-found=true >nul 2>&1
        )
        
        echo [SUCCESS] Kubernetes Goat removed
    )
)

:: Handle configuration file
if exist "!CONFIG_FILE!" (
    set /p REMOVE_CONFIG="Remove configuration file (!CONFIG_FILE!)? (y/N): "
    if /i "!REMOVE_CONFIG!"=="y" (
        del "!CONFIG_FILE!"
        echo [SUCCESS] Configuration file removed
    ) else (
        echo [WARNING] Configuration file preserved
    )
)

:: Handle Minikube
where minikube >nul 2>&1
if not errorlevel 1 (
    minikube status | findstr "Running" >nul 2>&1
    if not errorlevel 1 (
        echo.
        echo Minikube Options:
        echo 1. Stop Minikube (keep cluster for later use)
        echo 2. Delete Minikube cluster (complete removal)
        echo 3. Leave Minikube running
        echo.
        
        set /p MINIKUBE_OPTION="Choose option (1-3): "
        
        if "!MINIKUBE_OPTION!"=="1" (
            echo [STEP] Stopping Minikube...
            minikube stop
            echo [SUCCESS] Minikube stopped
        ) else if "!MINIKUBE_OPTION!"=="2" (
            echo [STEP] Deleting Minikube cluster...
            minikube delete
            echo [SUCCESS] Minikube cluster deleted
        ) else if "!MINIKUBE_OPTION!"=="3" (
            echo [WARNING] Leaving Minikube running
        ) else (
            echo [WARNING] Invalid option, leaving Minikube running
        )
    ) else (
        echo [WARNING] Minikube is not currently running
    )
) else (
    echo [WARNING] Minikube command not found
)

:: Show cleanup summary
echo.
echo === Teardown Summary ===
echo [SUCCESS] Cloudflare tunnel stopped
echo [SUCCESS] Temporary files cleaned up

if exist "!CONFIG_FILE!" (
    echo [WARNING] Configuration file preserved: !CONFIG_FILE!
) else (
    echo [SUCCESS] Configuration file removed
)

where minikube >nul 2>&1
if not errorlevel 1 (
    minikube status | findstr "Running" >nul 2>&1
    if not errorlevel 1 (
        echo [WARNING] Minikube cluster still running
    ) else (
        echo [SUCCESS] Minikube cluster stopped/deleted
    )
)

echo.
echo Teardown completed successfully!
echo Tip: Use 'teardown-k8s-cyberchief.bat --force' for emergency cleanup
goto end

:force_cleanup
echo === Force Cleanup Mode ===
echo [WARNING] Performing force cleanup...

:: Kill all cloudflared processes
taskkill /f /im cloudflared.exe >nul 2>&1

:: Remove all temporary files
if exist "tmp" rmdir /s /q "tmp" >nul 2>&1

:: Stop minikube if running
minikube stop >nul 2>&1

:: Remove config files
if exist "!CONFIG_FILE!" del "!CONFIG_FILE!" >nul 2>&1
if exist "k8s_cluster_config.json" del "k8s_cluster_config.json" >nul 2>&1
if exist "raider_manifest.yml" del "raider_manifest.yml" >nul 2>&1

echo [SUCCESS] Force cleanup completed
goto end

:show_help
echo Usage: teardown-k8s-cyberchief.bat [OPTIONS]
echo.
echo Options:
echo   --force, -f    Force cleanup (emergency mode)
echo   --help, -h     Show this help message
echo.
echo This script cleans up the setup created by setup-k8s-cyberchief.bat
goto end

:end
if not "%1"=="--force" if not "%1"=="-f" pause