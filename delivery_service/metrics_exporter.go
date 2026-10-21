package main

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	_ "github.com/lib/pq"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	totalOrders = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "total_orders_total",
			Help: "Общее количество заказов в базе данных",
		},
	)

	popularItems = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "popular_items_total",
			Help: "Количество заказанных порций по блюдам",
		},
		[]string{"item_name"},
	)
)

func init() {
	prometheus.MustRegister(totalOrders, popularItems)
}

func updateMetrics(db *sql.DB) {
	var count float64
	if err := db.QueryRow("SELECT COUNT(*) FROM orders").Scan(&count); err != nil {
		log.Printf("Ошибка получения количества заказов: %v", err)
		return
	}
	totalOrders.Set(count)

	rows, err := db.Query(`
		SELECT btrim(item_name) AS item_name, COUNT(*)::float8 AS orders_count
		FROM (
			SELECT unnest(string_to_array(order_items, ',')) AS item_name
			FROM orders
		) AS items
		WHERE btrim(item_name) <> ''
		GROUP BY btrim(item_name)
	`)
	if err != nil {
		log.Printf("Ошибка получения популярных блюд: %v", err)
		return
	}
	defer rows.Close()

	popularItems.Reset()
	for rows.Next() {
		var itemName string
		var ordersCount float64
		if err := rows.Scan(&itemName, &ordersCount); err != nil {
			log.Printf("Ошибка чтения строки метрики: %v", err)
			continue
		}
		popularItems.WithLabelValues(itemName).Set(ordersCount)
	}
	if err := rows.Err(); err != nil {
		log.Printf("Ошибка чтения метрик популярных блюд: %v", err)
	}
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

	db.SetMaxOpenConns(5)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// Ручка для Prometheus: метрики пересчитываются при каждом scrape
	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		updateMetrics(db)
		promhttp.Handler().ServeHTTP(w, r)
	})

	server := &http.Server{
		Addr:              ":8080",
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Println("Экспортер метрик на Go запущен на порту 8080...")
	log.Fatal(server.ListenAndServe())
}
