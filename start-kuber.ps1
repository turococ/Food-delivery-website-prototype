#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Stop
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectRoot

$MinikubeDir = "C:\Program Files\Kubernetes\Minikube"
$GitDir = "C:\Program Files\Git\cmd"
$env:Path = "$MinikubeDir;$GitDir;$env:Path"

$PidFile = Join-Path $env:TEMP "food-delivery-portforward.json"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Stop-Forwards {
    if (Test-Path $PidFile) {
        $items = Get-Content $PidFile -Raw | ConvertFrom-Json
        foreach ($item in @($items)) {
            Stop-Process -Id $item.Pid -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        Write-Host "Старые порт-форварды остановлены"
    }
}

function Wait-Deployment([string]$Namespace, [string]$Name, [int]$TimeoutSeconds = 300) {
    $found = & kubectl -n $Namespace get deployment $Name --ignore-not-found -o name 2>$null
    if (-not $found) { return }
    & kubectl -n $Namespace rollout status "deployment/$Name" --timeout="$($TimeoutSeconds)s" 2>$null
}

function Wait-StatefulSet([string]$Namespace, [string]$Name, [int]$TimeoutSeconds = 300) {
    $found = & kubectl -n $Namespace get statefulset $Name --ignore-not-found -o name 2>$null
    if (-not $found) { return }
    & kubectl -n $Namespace rollout status "statefulset/$Name" --timeout="$($TimeoutSeconds)s" 2>$null
}

if ($Stop) {
    Stop-Forwards
    & minikube stop
    Write-Host "Кластер остановлен." -ForegroundColor Green
    exit 0
}

if (-not (docker info 2>$null)) {
    Write-Host "Docker Desktop не запущен. Открой его и повтори." -ForegroundColor Red
    exit 1
}

$minikubeStatus = & minikube status --format "{{.Host}}" 2>$null
if ($minikubeStatus -ne "Running") {
    Write-Step "Запускаю minikube"
    & minikube start --driver=docker --memory=6144mb --cpus=4 --disk-size=20g
    if ($LASTEXITCODE -ne 0) {
        Write-Host "minikube не запустился. Проверь Docker Desktop." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "minikube уже запущен"
}

Write-Step "Жду готовности кластера"
& kubectl wait --for=condition=Ready node/minikube --timeout=180s | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Узел minikube не стал Ready." -ForegroundColor Red
    exit 1
}

Write-Host "Жду поды приложения и мониторинга..."
Wait-Deployment "default" "rabbitmq" 180
Wait-Deployment "default" "food-delivery" 300
Wait-Deployment "default" "worker" 180
Wait-Deployment "default" "metrics-exporter" 180
Wait-StatefulSet "default" "postgres" 180
Wait-Deployment "monitoring" "monitoring-grafana" 300
Wait-Deployment "monitoring" "monitoring-kube-prometheus-prometheus" 300
Wait-Deployment "argocd" "argocd-server" 300
Wait-Deployment "ingress-nginx" "ingress-nginx-controller" 300

Stop-Forwards

Write-Step "Запускаю порт-форварды"
$forwards = @(
    @{ Namespace = "ingress-nginx"; Service = "ingress-nginx-controller"; Ports = "8080:80";    Label = "Сайт" },
    @{ Namespace = "monitoring";    Service = "monitoring-grafana";           Ports = "3000:80";    Label = "Grafana" },
    @{ Namespace = "monitoring";    Service = "monitoring-kube-prometheus-prometheus"; Ports = "9090:9090"; Label = "Prometheus" },
    @{ Namespace = "argocd";        Service = "argocd-server";               Ports = "8443:443";   Label = "Argo CD" },
    @{ Namespace = "default";       Service = "rabbitmq";                    Ports = "15672:15672"; Label = "RabbitMQ UI" },
    @{ Namespace = "default";       Service = "metrics-exporter";            Ports = "8081:8080";  Label = "Metrics exporter" }
)

$kubectlPath = (Get-Command kubectl).Source
$started = @()
foreach ($forward in $forwards) {
    $arguments = @(
        "port-forward",
        "-n", $forward.Namespace,
        "svc/$($forward.Service)",
        $forward.Ports
    )
    $process = Start-Process -FilePath $kubectlPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $started += [pscustomobject]@{
        Pid       = $process.Id
        Label     = $forward.Label
        Namespace = $forward.Namespace
        Service   = $forward.Service
        Ports     = $forward.Ports
    }
}

$started | ConvertTo-Json | Set-Content -Path $PidFile -Encoding UTF8
Start-Sleep -Seconds 3

foreach ($item in $started) {
    if (-not (Get-Process -Id $item.Pid -ErrorAction SilentlyContinue)) {
        Write-Warning "Порт-форвард $($item.Label) не запустился (возможно, порт занят)."
    }
}

Write-Host ""
Write-Host "Готово. Открывай:" -ForegroundColor Green
Write-Host "  Сайт:             http://localhost:8080"
Write-Host "  Grafana:          http://localhost:3000"
Write-Host "  Prometheus:       http://localhost:9090"
Write-Host "  Argo CD:          https://localhost:8443"
Write-Host "  RabbitMQ UI:      http://localhost:15672"
Write-Host "  Metrics exporter: http://localhost:8081/metrics"
Write-Host ""
Write-Host "Остановка: .\start-kuber.ps1 -Stop" -ForegroundColor DarkGray
