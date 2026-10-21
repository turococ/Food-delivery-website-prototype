# Food Delivery: CI/CD и мониторинг в Kubernetes

Учебный DevOps-проект: сайт доставки еды на Flask, очередь заказов в RabbitMQ, PostgreSQL, воркер, экспортёр метрик, GitOps-деплой через Argo CD и мониторинг в Prometheus/Grafana.

```
Браузер → Flask (web) → RabbitMQ (order_queue) → worker → PostgreSQL
                                                       ↓
                                              metrics-exporter → Prometheus → Grafana
```

```
git push → GitLab CI (build 3 images) → Container Registry
        → CI обновляет image tags в k8s/ → Argo CD → Kubernetes
```

## Стек

| Назначение | Инструмент |
|---|---|
| Приложение | Python 3.12, Flask, gunicorn |
| Очередь | RabbitMQ 3.13 |
| База данных | PostgreSQL 16 |
| Метрики | Go, prometheus/client_golang |
| Контейнеризация | Docker |
| CI | GitLab CI/CD, GitLab Container Registry |
| Деплой | Argo CD (GitOps) |
| Оркестрация | Kubernetes (minikube) |
| Мониторинг | Prometheus, Grafana (kube-prometheus-stack) |

## Структура

```
.
├── argocd/                  # Argo CD Application
├── delivery_service/        # Flask, worker, Go exporter, Dockerfile'ы
├── k8s/                     # манифесты приложения и мониторинга
├── monitoring/values.yaml   # настройки kube-prometheus-stack
├── setup.ps1                # установка стека на Windows
├── start-kuber.ps1          # запуск и порт-форварды на Windows
├── setup.sh                 # установка на macOS/Linux
├── start-kuber.sh           # запуск на macOS/Linux
└── .gitlab-ci.yml           # сборка образов и обновление тегов
```

## Требования

- Docker Desktop (рекомендуется 8+ ГБ памяти).
- Windows: PowerShell 5.1+, `winget`.
- macOS: Homebrew (скрипт предложит установить).
- Свободные порты `8080`, `3000`, `9090`, `8443`, `15672`, `8081`.

## Быстрый старт (Windows)

```powershell
git clone https://gitlab.com/turococ/Food-delivery-website-prototype.git
cd Food-delivery-website-prototype
.\setup.ps1
```

Скрипт:

1. установит `minikube`, `helm`, `git`, если их нет;
2. запустит minikube (6 ГБ RAM, 4 CPU);
3. включит ingress;
4. установит Prometheus/Grafana;
5. установит Argo CD;
6. создаст секреты PostgreSQL, RabbitMQ и приложения;
7. применит `argocd/application.yaml` и дождётся деплоя;
8. запустит `start-kuber.ps1` с порт-форвардами.

Если PowerShell блокирует запуск:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
```

Остановка:

```powershell
.\start-kuber.ps1 -Stop
```

Повторный запуск:

```powershell
.\start-kuber.ps1
```

## Быстрый старт (macOS)

```bash
git clone https://gitlab.com/turococ/Food-delivery-website-prototype.git
cd Food-delivery-website-prototype
make setup
make start
```

Остановка: `make stop`.

## Адреса

| Что | Адрес |
|---|---|
| Сайт | http://localhost:8080 |
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9090 |
| Argo CD | https://localhost:8443 |
| RabbitMQ UI | http://localhost:15672 |
| Метрики exporter | http://localhost:8081/metrics |

`cafe.local` тоже поддерживается ingress'ом. Чтобы открыть `http://cafe.local:8080`, добавьте в `C:\Windows\System32\drivers\etc\hosts` (нужны права администратора):

```
127.0.0.1 cafe.local
```

## Доступы

Пароли генерируются при установке и хранятся в Kubernetes Secrets.

```powershell
# Пароль администратора сайта
kubectl get secret app-secret -o jsonpath="{.data.ADMIN_PASSWORD}" | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }

# Пароль Grafana
kubectl get secret monitoring-grafana -n monitoring -o jsonpath="{.data.admin-password}" | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }

# Пароль Argo CD (логин admin)
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

Логин администратора сайта: `admin`. Пароль выводится в конце `setup.ps1`.
RabbitMQ: пользователь `food`, пароль — в секрете `rabbitmq-secret`.

## Метрики

Экспортёр отдаёт на `/metrics`:

- `total_orders_total` — общее число заказов в БД;
- `popular_items_total{item_name="..."}` — сколько порций каждого блюда заказано.

Примеры запросов в Prometheus:

```
total_orders_total
popular_items_total
topk(5, popular_items_total)
sum(increase(total_orders_total[1h]))
```

Grafana-дашборд `site metrics` подхватывается автоматически из ConfigMap.

## CI/CD

1. Push в `main` запускает GitLab CI.
2. Собираются три образа с тегом `$CI_COMMIT_SHA` и пушатся в registry:
   - `web`
   - `worker`
   - `metrics-exporter`
3. Job `update_manifests` меняет теги в `k8s/deployment.yaml`, `k8s/worker.yaml`, `k8s/metrics_exporter.yaml` и коммитит с `[skip ci]`.
4. Argo CD замечает новый коммит (reconciliation 60 секунд) и выкатывает приложение.
5. `latest` обновляется только из `main`; в merge request собираются только SHA-теги.

Для шага 3 нужна CI/CD-переменная `GIT_PUSH_TOKEN`:

- GitLab → проект → **Settings → Access Tokens**;
- роль **Maintainer**, scope **write_repository**;
- добавить в **Settings → CI/CD → Variables** как `GIT_PUSH_TOKEN`, masked и protected.

Без токена пайплайн соберёт образы, но не сможет обновить манифесты. Argo CD при этом продолжит работать с текущими тегами.

### Почему CI не делает `kubectl apply`

GitLab.com shared runner не имеет доступа к локальному minikube. Поэтому деплой сделан по GitOps: CI обновляет Git, а кластер синхронизирует Argo CD. Если нужен прямой `kubectl` из CI, понадобится self-hosted GitLab Runner в этой же сети.

## Разработка без Kubernetes

Приложение читает настройки из переменных окружения:

| Переменная | Значение по умолчанию |
|---|---|
| `DB_HOST` | `localhost` |
| `DB_PORT` | `5432` |
| `DB_NAME` | `food_delivery` |
| `DB_USER` | `food` |
| `DB_PASSWORD` | пусто |
| `RABBITMQ_HOST` | `localhost` |
| `RABBITMQ_PORT` | `5672` |
| `RABBITMQ_USER` | `guest` |
| `RABBITMQ_PASSWORD` | `guest` |
| `SECRET_KEY` | `dev-secret-change-me` |
| `ADMIN_USERNAME` | `admin` |
| `ADMIN_PASSWORD` | `admin` |

Для локального запуска поднимите PostgreSQL и RabbitMQ, затем:

```bash
pip install -r delivery_service/requirements.txt
cd delivery_service
python app.py
```

Воркер запускается отдельно:

```bash
pip install -r delivery_service/requirements-worker.txt
cd delivery_service
python worker.py
```

## Проверка

```powershell
kubectl get pods -A
kubectl get application -n argocd
kubectl logs -l app=worker --tail=50
kubectl logs -l app=metrics-exporter --tail=50
```

Сценарий проверки:

1. Открыть сайт, добавить блюда в корзину.
2. Оформить заказ.
3. Убедиться, что в логах worker'а есть `Заказ успешно сохранён в БД`.
4. Войти в админку и сменить статус заказа.
5. Открыть Grafana и проверить рост `total_orders_total`.

## Troubleshooting

**Поды в `ImagePullBackOff`.** Проверьте, что в манифестах указаны образы `.../web`, `.../worker`, `.../metrics-exporter` (не корневой репозиторий).

**Сайт открывается, но заказ не создаётся.** Проверьте RabbitMQ:

```powershell
kubectl logs deployment/rabbitmq
kubectl logs deployment/worker
```

Пользователь `guest` в RabbitMQ разрешён только с localhost, поэтому в кластере используется `food`.

**Argo CD не синхронизирует.** Проверьте:

```powershell
kubectl describe application food-delivery -n argocd
kubectl logs deployment/argocd-repo-server -n argocd
```

**Не хватает памяти.** Уменьшите ресурсы мониторинга в `monitoring/values.yaml` или выделите Docker больше памяти (Docker Desktop → Settings → Resources).

**Порт занят.** Измените левую часть порт-форварда в `start-kuber.ps1`, например `8082:80`, и откройте `http://localhost:8082`.
