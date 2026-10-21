#!/usr/bin/env bash

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

SITE_HOST="cafe.local"
: "${MINIKUBE_MEMORY_MB:=6144}"
: "${MINIKUBE_CPUS:=4}"


fail() {
    echo "ОШИБКА: $*" >&2
    exit 1
}

ask_yes_no() {
    local reply
    read -rp "$1 (y/n) " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

wait_for() {
    local description="$1" timeout="$2" check="$3" elapsed=0
    until eval "$check" &>/dev/null; do
        if (( elapsed >= timeout )); then
            echo "Не дождался: $description"
            return 1
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
}

ensure_brew() {
    command -v brew &>/dev/null && return 0
    ask_yes_no "Homebrew не найден. Установить?" || fail "Без Homebrew не могу установить инструменты."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || fail "Установка Homebrew не удалась."
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    command -v brew &>/dev/null || fail "Homebrew установлен, но не найден в PATH. Открой новый терминал и запусти скрипт снова."
}

install_tool() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        fail "Автоустановка есть только для macOS. Установи $1 вручную и запусти скрипт снова."
    fi
    ensure_brew
    case "$1" in
        minikube) brew install minikube ;;
        kubectl)  brew install kubectl ;;
        helm)     brew install helm ;;
        docker)   brew install --cask docker ;;
    esac
}

new_password() {
    openssl rand -hex 16
}

ensure_secret() {
    local name="$1"
    shift
    if kubectl get secret "$name" &>/dev/null; then
        echo "Секрет $name уже существует"
        return
    fi
    kubectl create secret generic "$name" "$@" >/dev/null
    echo "Создан секрет $name"
}

secret_value() {
    local name="$1" key="$2"
    kubectl get secret "$name" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || true
}


for tool in minikube kubectl helm docker; do
    if command -v "$tool" &>/dev/null; then
        echo "$tool: установлен"
        continue
    fi
    echo "$tool не найден."
    ask_yes_no "Установить $tool?" || fail "$tool не установлен, остановка."
    install_tool "$tool"
    command -v "$tool" &>/dev/null || fail "не удалось установить $tool"
done


if ! docker info &>/dev/null; then
    fail "Docker не запущен. Открой Docker Desktop, дождись статуса Running и запусти скрипт снова."
fi

docker_mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
docker_mem_mb=$(( docker_mem_bytes / 1024 / 1024 ))
needed_mb=$(( MINIKUBE_MEMORY_MB + 512 ))
if (( docker_mem_mb < needed_mb )); then
    fail "Docker выделено ${docker_mem_mb} МБ, нужно хотя бы ${needed_mb} МБ. Увеличь память или уменьши MINIKUBE_MEMORY_MB."
fi


if minikube status &>/dev/null; then
    echo "minikube уже запущен."
else
    echo "Запускаю minikube (память ${MINIKUBE_MEMORY_MB} МБ, процессоров ${MINIKUBE_CPUS})..."
    minikube start --driver=docker --memory="${MINIKUBE_MEMORY_MB}mb" --cpus="$MINIKUBE_CPUS" \
        || fail "minikube не запустился. Если Docker завис, перезапусти Docker Desktop."
fi

kubectl wait --for=condition=Ready node/minikube --timeout=180s || fail "Узел minikube не стал Ready."

echo "Включаю Ingress..."
minikube addons enable ingress || fail "Не удалось включить Ingress."
wait_for "под ingress-контроллера" 180 \
    'kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o name | grep -q .' \
    || fail "Ingress-контроллер не появился."
kubectl wait --namespace ingress-nginx --for=condition=Ready pod \
    --selector=app.kubernetes.io/component=controller --timeout=300s \
    || fail "Ingress-контроллер не стал Ready."


echo "Ставлю мониторинг..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null \
    || fail "Не удалось добавить репозиторий Helm."
helm repo update >/dev/null

if [[ -f monitoring/values.yaml ]]; then
    helm_args=(-f monitoring/values.yaml)
else
    helm_args=(--set alertmanager.enabled=false --set prometheus.prometheusSpec.resources.requests.memory=400Mi)
fi

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace --timeout 15m "${helm_args[@]}" \
    || fail "Не удалось установить мониторинг через Helm."

kubectl wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=180s \
    || fail "CRD ServiceMonitor не появился."


echo "Ставлю Argo CD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - || fail "Не удалось создать namespace argocd."
kubectl apply -n argocd --server-side --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
    || fail "Не удалось применить манифест Argo CD."

kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=180s \
    || fail "CRD Application не появился."
kubectl rollout status deployment/argocd-server -n argocd --timeout=600s || fail "argocd-server не запустился."
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=600s || fail "argocd-repo-server не запустился."
if kubectl get statefulset argocd-application-controller -n argocd &>/dev/null; then
    kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=600s || true
fi

kubectl -n argocd patch configmap argocd-cm --type merge \
    -p '{"data":{"timeout.reconciliation":"60s"}}' >/dev/null 2>&1 || true

for component in argocd-dex-server argocd-notifications-controller argocd-applicationset-controller; do
    if kubectl -n argocd get deployment "$component" &>/dev/null; then
        kubectl -n argocd scale deployment "$component" --replicas=0 >/dev/null
    fi
done


echo "Создаю секреты..."
ensure_secret postgres-secret --from-literal=POSTGRES_PASSWORD="$(new_password)"
ensure_secret rabbitmq-secret \
    --from-literal=username=food \
    --from-literal=password="$(new_password)"
ensure_secret app-secret \
    --from-literal=SECRET_KEY="$(new_password)" \
    --from-literal=ADMIN_USERNAME=admin \
    --from-literal=ADMIN_PASSWORD="$(new_password)"


if [[ -f argocd/application.yaml ]]; then
    kubectl apply -f argocd/application.yaml || fail "Не удалось применить argocd/application.yaml."
    echo "Жду, пока Argo CD развернёт сайт..."
    if wait_for "Deployment food-delivery" 600 'kubectl get deployment food-delivery -n default'; then
        kubectl rollout status deployment/food-delivery -n default --timeout=600s \
            || echo "Предупреждение: сайт ещё не готов. Проверь: kubectl get pods"
    else
        echo "Предупреждение: Argo CD пока не создал сайт. Проверь приложение в интерфейсе Argo CD."
    fi
else
    echo "Предупреждение: нет файла argocd/application.yaml, сайт не развернут."
fi

if ! grep -q "$SITE_HOST" /etc/hosts; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        host_ip="127.0.0.1"
    else
        host_ip="$(minikube ip)"
    fi
    echo "Добавляю $SITE_HOST в /etc/hosts (потребуется пароль)..."
    echo "$host_ip $SITE_HOST" | sudo tee -a /etc/hosts >/dev/null || echo "Предупреждение: не удалось изменить /etc/hosts."
fi

echo
echo "Готово."
echo "  Сайт:          http://localhost:8080"
echo "  Grafana:       http://localhost:3000"
echo "  Prometheus:    http://localhost:9090"
echo "  Argo CD:       https://localhost:8443"
echo "  RabbitMQ UI:   http://localhost:15672"
echo
echo "  Пароль админа сайта: $(secret_value app-secret ADMIN_PASSWORD)"
echo "  Пароль Argo CD:      $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "  Пароль Grafana:      $(kubectl get secret monitoring-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)"
echo
echo "Запусти ./start-kuber.sh, чтобы поднять порт-форварды."
