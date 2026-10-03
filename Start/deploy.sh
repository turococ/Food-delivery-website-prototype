#!/usr/bin/env bash

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

REPO_URL="https://gitlab.com/turococ/Food-delivery-website-prototype.git"
SITE_HOST="cafe.local"
: "${MINIKUBE_MEMORY_MB:=4096}"
: "${MINIKUBE_CPUS:=2}"


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


if [[ -f .env ]]; then
    set -a
    . ./.env
    set +a
fi

if [[ -z "${GITLAB_DEPLOY_USER:-}" ]]; then
    read -rp "GitLab Deploy token: имя пользователя: " GITLAB_DEPLOY_USER
fi
if [[ -z "${GITLAB_DEPLOY_TOKEN:-}" ]]; then
    read -rsp "GitLab Deploy token: токен (ввод не отображается): " GITLAB_DEPLOY_TOKEN
    echo
fi
[[ -n "$GITLAB_DEPLOY_USER" && -n "$GITLAB_DEPLOY_TOKEN" ]] || fail "Нужны имя пользователя и токен GitLab Deploy token."


if minikube status &>/dev/null; then
    echo "minikube уже запущен."
else
    echo "Запускаю minikube (память ${MINIKUBE_MEMORY_MB} МБ, процессоров ${MINIKUBE_CPUS})..."
    minikube start --driver=docker --memory="$MINIKUBE_MEMORY_MB" --cpus="$MINIKUBE_CPUS" \
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


echo "Ставлю мониторинг (первый раз это несколько минут)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null \
    || fail "Не удалось добавить репозиторий Helm."
helm repo update >/dev/null

if [[ -f monitoring/values.yaml ]]; then
    helm_args=(-f monitoring/values.yaml)
else
    helm_args=(--set alertmanager.enabled=false --set prometheus.prometheusSpec.resources.requests.memory=400Mi)
fi

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace --timeout 10m "${helm_args[@]}" \
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
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s || fail "argocd-server не запустился."
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s || fail "argocd-repo-server не запустился."

echo "Создаю секреты..."
kubectl create secret docker-registry gitlab-registry \
    --docker-server=registry.gitlab.com \
    --docker-username="$GITLAB_DEPLOY_USER" \
    --docker-password="$GITLAB_DEPLOY_TOKEN" \
    --docker-email="deploy@example.com" \
    --dry-run=client -o yaml | kubectl apply -f - || fail "Не удалось создать секрет gitlab-registry."

kubectl create secret generic gitlab-repo -n argocd \
    --from-literal=type=git \
    --from-literal=url="$REPO_URL" \
    --from-literal=username="$GITLAB_DEPLOY_USER" \
    --from-literal=password="$GITLAB_DEPLOY_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f - || fail "Не удалось создать секрет gitlab-repo."
kubectl label secret gitlab-repo -n argocd argocd.argoproj.io/secret-type=repository --overwrite \
    || fail "Не удалось пометить секрет gitlab-repo."

if [[ -f argocd/application.yaml ]]; then
    kubectl apply -f argocd/application.yaml || fail "Не удалось применить argocd/application.yaml."
    echo "Жду, пока Argo CD развернёт сайт (обычно 1-3 минуты)..."
    if wait_for "Deployment food-delivery" 360 'kubectl get deployment food-delivery -n default'; then
        kubectl rollout status deployment/food-delivery -n default --timeout=300s \
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
echo "  1. В отдельном окне терминала запусти:  minikube tunnel   (только macOS)"
echo "  2. Сайт:  http://$SITE_HOST"
echo "  3. Пароль Argo CD (логин admin):"
echo "       kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d; echo"
echo "  4. Пароль Grafana (логин admin):"
echo "       kubectl get secret monitoring-grafana -n monitoring -o jsonpath=\"{.data.admin-password}\" | base64 -d; echo"
echo "  5. Ежедневный запуск: ./start-kuber.sh"