.PHONY: setup start stop tunnel status build push deploy logs-web logs-worker logs-metrics setup-win start-win stop-win

setup:
	bash ./setup.sh

start:
	bash ./start-kuber.sh

stop:
	bash ./start-kuber.sh stop

tunnel:
	minikube tunnel

status:
	kubectl get pods -A

# Windows (PowerShell)
setup-win:
	powershell -ExecutionPolicy Bypass -File setup.ps1

start-win:
	powershell -ExecutionPolicy Bypass -File start-kuber.ps1

stop-win:
	powershell -ExecutionPolicy Bypass -File start-kuber.ps1 -Stop

build:
	docker build -t food-delivery-web:local -f delivery_service/Dockerfile delivery_service/
	docker build -t food-delivery-metrics:local -f delivery_service/Dockerfile.go delivery_service/
	docker build -t food-delivery-worker:local -f delivery_service/Dockerfile.worker delivery_service/

push:
	docker tag food-delivery-web:local $$REGISTRY/web:latest
	docker tag food-delivery-metrics:local $$REGISTRY/metrics-exporter:latest
	docker tag food-delivery-worker:local $$REGISTRY/worker:latest
	docker push $$REGISTRY/web:latest
	docker push $$REGISTRY/metrics-exporter:latest
	docker push $$REGISTRY/worker:latest

deploy:
	kubectl apply -f argocd/application.yaml

logs-web:
	kubectl logs -l app=food-delivery -f --tail=100

logs-worker:
	kubectl logs -l app=worker -f --tail=100

logs-metrics:
	kubectl logs -l app=metrics-exporter -f --tail=100
