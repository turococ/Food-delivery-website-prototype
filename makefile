.PHONY: setup start stop tunnel status

setup:
	bash ./deploy.sh

start:
	bash ./start-kuber.sh


tunnel:
	minikube tunnel

stop:
	./start-kuber.sh stop

status:
	kubectl get pods -A