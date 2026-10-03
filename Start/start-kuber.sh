#!/usr/bin/env bash

set -uo pipefail
 
PID_FILE="/tmp/kuber-portforward.pids"
 
stop_forwards() {
    if [[ -f "$PID_FILE" ]]; then
        while read -r pid; do
            kill "$pid" 2>/dev/null || true
        done < "$PID_FILE"
        rm -f "$PID_FILE"
    fi
}
 
start_forward() {
    local namespace="$1" service="$2" ports="$3"
    kubectl port-forward -n "$namespace" "svc/$service" "$ports" >/dev/null 2>&1 &
    echo $! >> "$PID_FILE"
}
 
if [[ "${1:-}" == "stop" ]]; then
    stop_forwards
    minikube stop
    echo "Кластер остановлен."
    exit 0
fi
 
if ! docker info &>/dev/null; then
    echo "Docker не запущен. Открой Docker Desktop, дождись статуса Running и запусти скрипт снова."
    exit 1
fi
 
if ! minikube status &>/dev/null; then
    echo "Запускаю minikube..."
    if ! minikube start; then
        echo "minikube не запустился. Если Docker завис после сна, перезапусти Docker Desktop и повтори."
        exit 1
    fi
else
    echo "minikube уже запущен."
fi
 
echo "Жду готовности узла..."
if ! kubectl wait --for=condition=Ready node/minikube --timeout=180s; then
    echo "Узел не стал Ready. Проверь: minikube status"
    exit 1
fi
 
echo "Жду поды (до нескольких минут после холодного старта)..."
kubectl rollout status deployment/food-delivery -n default --timeout=180s \
    || echo "Предупреждение: food-delivery ещё не готов (kubectl get pods)."
kubectl rollout status deployment/monitoring-grafana -n monitoring --timeout=300s \
    || echo "Предупреждение: Grafana ещё не готова (kubectl get pods -n monitoring)."
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s \
    || echo "Предупреждение: Argo CD ещё не готов (kubectl get pods -n argocd)."
 
stop_forwards
start_forward monitoring monitoring-grafana 3000:80
start_forward monitoring monitoring-kube-prometheus-prometheus 9090:9090
start_forward argocd argocd-server 8443:443
 
if ! grep -q "cafe.local" /etc/hosts; then
    echo "В /etc/hosts нет cafe.local. Добавь: echo \"127.0.0.1 cafe.local\" | sudo tee -a /etc/hosts"
fi
 
echo
echo "Готово."
echo "  Сайт:       http://cafe.local   (нужен minikube tunnel в отдельном окне терминала)"
echo "  Grafana:    http://localhost:3000"
echo "  Prometheus: http://localhost:9090"
echo "  Argo CD:    https://localhost:8443"
echo
echo "Если после деплоя или перезапуска пода проброс отвалился, запусти скрипт ещё раз."
echo "Остановить всё: ./start-kuber.sh stop"
 
