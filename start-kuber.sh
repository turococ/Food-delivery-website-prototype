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
    if ! minikube start --driver=docker --memory=6144mb --cpus=4; then
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

echo "Жду поды..."
kubectl rollout status statefulset/postgres -n default --timeout=180s \
    || echo "Предупреждение: postgres ещё не готов."
kubectl rollout status deployment/rabbitmq -n default --timeout=180s \
    || echo "Предупреждение: rabbitmq ещё не готов."
kubectl rollout status deployment/food-delivery -n default --timeout=300s \
    || echo "Предупреждение: food-delivery ещё не готов."
kubectl rollout status deployment/worker -n default --timeout=180s \
    || echo "Предупреждение: worker ещё не готов."
kubectl rollout status deployment/metrics-exporter -n default --timeout=180s \
    || echo "Предупреждение: metrics-exporter ещё не готов."
kubectl rollout status deployment/monitoring-grafana -n monitoring --timeout=300s \
    || echo "Предупреждение: Grafana ещё не готова."
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s \
    || echo "Предупреждение: Argo CD ещё не готов."

stop_forwards
start_forward ingress-nginx ingress-nginx-controller 8080:80
start_forward monitoring monitoring-grafana 3000:80
start_forward monitoring monitoring-kube-prometheus-prometheus 9090:9090
start_forward argocd argocd-server 8443:443
start_forward default rabbitmq 15672:15672
start_forward default metrics-exporter 8081:8080

if ! grep -q "cafe.local" /etc/hosts; then
    echo "В /etc/hosts нет cafe.local. Сайт доступен по http://localhost:8080."
    echo "Для cafe.local добавь: echo \"127.0.0.1 cafe.local\" | sudo tee -a /etc/hosts"
fi

echo
echo "Готово."
echo "  Сайт:             http://localhost:8080"
echo "  Grafana:          http://localhost:3000"
echo "  Prometheus:       http://localhost:9090"
echo "  Argo CD:          https://localhost:8443"
echo "  RabbitMQ UI:      http://localhost:15672"
echo "  Metrics exporter: http://localhost:8081/metrics"
echo
echo "Остановка: ./start-kuber.sh stop"
