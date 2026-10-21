#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectRoot

$MinikubeDir = "C:\Program Files\Kubernetes\Minikube"
$GitDir = "C:\Program Files\Git\cmd"
$env:Path = "$MinikubeDir;$GitDir;$env:Path"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Fail([string]$Message) {
    Write-Host "ОШИБКА: $Message" -ForegroundColor Red
    exit 1
}

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
                [Environment]::GetEnvironmentVariable("Path", "User") + ";" + `
                "$MinikubeDir;$GitDir"
}

function Ensure-Tool([string]$Name, [string]$WingetId) {
    Refresh-Path
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    Write-Step "Устанавливаю $Name через winget..."
    winget install --id $WingetId -e --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Fail "$Name не найден после установки. Закрой и открой терминал заново, затем запусти setup.ps1."
    }
    return $cmd.Source
}

function New-RandomString([int]$Length = 24) {
    $chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
    $result = for ($i = 0; $i -lt $Length; $i++) {
        $chars[(Get-Random -Maximum $chars.Length)]
    }
    return -join $result
}

function Ensure-Secret([string]$Name, [hashtable]$Values) {
    $existing = & kubectl get secret $Name --ignore-not-found -o name 2>$null
    if ($existing) {
        Write-Host "Секрет $Name уже существует"
        return
    }

    $arguments = @("create", "secret", "generic", $Name)
    foreach ($key in $Values.Keys) {
        $arguments += "--from-literal=$key=$($Values[$key])"
    }
    & kubectl @arguments | Out-Null
    Write-Host "Создан секрет $Name"
}

function Get-SecretValue([string]$Secret, [string]$Key) {
    $encoded = & kubectl get secret $Secret --ignore-not-found -o "jsonpath={.data.$Key}" 2>$null
    if (-not $encoded) { return "" }
    try {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
    } catch {
        return ""
    }
}

Write-Step "Проверяю инструменты"
Ensure-Tool "kubectl" "Kubernetes.kubectl" | Out-Null
Ensure-Tool "minikube" "Kubernetes.minikube" | Out-Null
Ensure-Tool "helm" "Helm.Helm" | Out-Null
Ensure-Tool "git" "Git.Git" | Out-Null

Write-Step "Проверяю Docker"
if (-not (docker info 2>$null)) {
    Fail "Docker Desktop не запущен. Открой его, дождись статуса Running и запусти setup.ps1 снова."
}
$dockerMem = [int64](docker info --format '{{.MemTotal}}' 2>$null)
$dockerMemGb = [math]::Round($dockerMem / 1GB, 1)
Write-Host "Docker доступно памяти: $dockerMemGb ГБ"
if ($dockerMemGb -lt 7) {
    Write-Warning "Для minikube с 6 ГБ рекомендуется выделить Docker не менее 8 ГБ (Settings -> Resources)."
}

Write-Step "Запускаю minikube"
$minikubeStatus = & minikube status --format "{{.Host}}" 2>$null
if ($minikubeStatus -ne "Running") {
    & minikube start --driver=docker --memory=6144mb --cpus=4 --disk-size=20g
    if ($LASTEXITCODE -ne 0) { Fail "minikube не запустился." }
} else {
    Write-Host "minikube уже запущен"
}

& kubectl wait --for=condition=Ready node/minikube --timeout=180s | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Узел minikube не стал Ready." }

Write-Step "Включаю ingress"
& minikube addons enable ingress
if ($LASTEXITCODE -ne 0) { Fail "Не удалось включить ingress addon." }

Write-Host "Жду ingress-контроллер..."
& kubectl wait --namespace ingress-nginx --for=condition=Ready pod `
    --selector=app.kubernetes.io/component=controller --timeout=300s | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Ingress-контроллер не стал Ready." }

Write-Step "Ставлю Prometheus + Grafana"
& helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update | Out-Null
& helm repo update | Out-Null
& helm upgrade --install monitoring prometheus-community/kube-prometheus-stack `
    -n monitoring --create-namespace -f monitoring/values.yaml --timeout 15m
if ($LASTEXITCODE -ne 0) { Fail "Не удалось установить kube-prometheus-stack." }

& kubectl wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=180s | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "CRD ServiceMonitor не появился." }

Write-Host "Жду секрет Grafana..."
$grafanaSecret = $null
$grafanaDeadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $grafanaDeadline) {
    $grafanaSecret = & kubectl get secret monitoring-grafana -n monitoring --ignore-not-found -o name 2>$null
    if ($grafanaSecret) { break }
    Start-Sleep -Seconds 2
}
if (-not $grafanaSecret) {
    Write-Warning "Секрет monitoring-grafana пока не появился; пароль Grafana можно посмотреть позже."
}

Write-Step "Ставлю Argo CD"
& kubectl create namespace argocd --dry-run=client -o yaml | & kubectl apply -f - | Out-Null
& kubectl apply -n argocd --server-side --force-conflicts `
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
if ($LASTEXITCODE -ne 0) { Fail "Не удалось применить манифест Argo CD." }

& kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=180s | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "CRD Application не появился." }

Write-Host "Жду компоненты Argo CD..."
& kubectl -n argocd rollout status deployment/argocd-server --timeout=600s
& kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=600s
$controller = & kubectl -n argocd get statefulset argocd-application-controller --ignore-not-found -o name 2>$null
if ($controller) {
    & kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s
}

# Ускоряем реакцию Argo CD на новые коммиты
$patchFile = Join-Path $env:TEMP "argocd-cm-patch.json"
'{"data":{"timeout.reconciliation":"60s"}}' | Set-Content -Path $patchFile -Encoding ASCII
& kubectl -n argocd patch configmap argocd-cm --type merge --patch-file $patchFile | Out-Null
Remove-Item $patchFile -Force -ErrorAction SilentlyContinue

# Отключаем необязательные компоненты, чтобы сэкономить память
foreach ($component in @("argocd-dex-server", "argocd-notifications-controller", "argocd-applicationset-controller")) {
    $found = & kubectl -n argocd get deployment $component --ignore-not-found -o name 2>$null
    if ($found) {
        & kubectl -n argocd scale deployment $component --replicas=0 | Out-Null
    }
}

Write-Step "Создаю секреты"
$postgresPassword = New-RandomString 24
Ensure-Secret "postgres-secret" @{ "POSTGRES_PASSWORD" = $postgresPassword }

$rabbitUser = "food"
$rabbitPassword = New-RandomString 24
Ensure-Secret "rabbitmq-secret" @{
    "username" = $rabbitUser
    "password" = $rabbitPassword
}

Ensure-Secret "app-secret" @{
    "SECRET_KEY"     = New-RandomString 40
    "ADMIN_USERNAME" = "admin"
    "ADMIN_PASSWORD" = New-RandomString 16
}

Write-Step "Применяю Argo CD Application"
& kubectl apply -f argocd/application.yaml
if ($LASTEXITCODE -ne 0) { Fail "Не удалось применить argocd/application.yaml." }

Write-Host "Жду, пока Argo CD развернёт приложение..."
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    $deployment = & kubectl get deployment food-delivery --ignore-not-found -o name 2>$null
    if ($deployment) { break }
    Start-Sleep -Seconds 10
}

if (-not $deployment) {
    Write-Warning "Argo CD ещё не создал Deployment. Проверь приложение в UI Argo CD."
} else {
    & kubectl rollout status deployment/food-delivery --timeout=600s
}

Write-Step "Готово"
$adminPassword = Get-SecretValue "app-secret" "ADMIN_PASSWORD"
$rabbitPasswordActual = Get-SecretValue "rabbitmq-secret" "password"

Write-Host ""
Write-Host "Сайт:          http://localhost:8080" -ForegroundColor Green
Write-Host "Grafana:       http://localhost:3000 (admin / см. секрет monitoring-grafana)" -ForegroundColor Green
Write-Host "Prometheus:    http://localhost:9090" -ForegroundColor Green
Write-Host "Argo CD:       https://localhost:8443 (admin / см. секрет argocd-initial-admin-secret)" -ForegroundColor Green
Write-Host "RabbitMQ UI:   http://localhost:15672 ($rabbitUser / $rabbitPasswordActual)" -ForegroundColor Green
Write-Host ""
Write-Host "Админка сайта: admin / $adminPassword" -ForegroundColor Yellow
Write-Host ""

$grafanaPassword = Get-SecretValue "monitoring-grafana" "admin-password"
$argocdPassword = Get-SecretValue "argocd-initial-admin-secret" "password"
if ($grafanaPassword) { Write-Host "Grafana admin password: $grafanaPassword" }
if ($argocdPassword) { Write-Host "Argo CD admin password: $argocdPassword" }

Write-Host ""
Write-Host "Запускаю порт-форварды..."
& (Join-Path $ProjectRoot "start-kuber.ps1")
