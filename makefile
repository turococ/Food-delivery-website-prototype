.PHONY: setup start stop tunnel status build push deploy logs

setup:
	bash ./setup.sh

start:
	bash ./start-kuber.sh

tunnel:
	minikube tunnel

stop:
	./start-kuber.sh stop

status:
	kubectl get pods -A

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
	kubectl patch application food-delivery -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"make"}}}'

logs-web:
	kubectl logs -l app=food-delivery -f --tail=100

logs-worker:
	kubectl logs -l app=worker -f --tail=100

logs-metrics:
	kubectl logs -l app=metrics-exporter -f --tail=100