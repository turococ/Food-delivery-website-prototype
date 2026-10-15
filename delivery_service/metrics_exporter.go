package main

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"

	_ "github.com/lib/pq"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	totalOrders = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "total_orders",
			Help: "Общее количество заказов в базе данных",
		},
	)
)

func init() {
	prometheus.MustRegister(totalOrders)
}

func updateMetrics(db *sql.DB) {
	var count float64
	err := db.QueryRow("SELECT COUNT(*) FROM orders").Scan(&count)
	if err != nil {
		log.Printf("Ошибка получения метрики из БД: %v", err)
		return
	}
	totalOrders.Set(count)
}

func main() {
	dbHost := os.Getenv("DB_HOST")
	dbPort := os.Getenv("DB_PORT")
	dbUser := os.Getenv("DB_USER")
	dbPassword := os.Getenv("DB_PASSWORD")
	dbName := os.Getenv("DB_NAME")

	connStr := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		dbHost, dbPort, dbUser, dbPassword, dbName)

	db, err := sql.Open("postgres", connStr)
	if err != nil {
		log.Fatalf("Ошибка подключения к БД: %v", err)
	}
	defer db.Close()

	// Ручка для Prometheus
	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		updateMetrics(db)
		promhttp.Handler().ServeHTTP(w, r)
	})

	log.Println("Экспортер метрик на Go запущен на порту 8080...")
	log.Fatal(http.ListenAndServe(":8080", nil))
}