import pika
import json
import time
import os
import psycopg2
import psycopg2.extras

DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "postgres"),
    "port": os.environ.get("DB_PORT", "5432"),
    "dbname": os.environ.get("DB_NAME", "food_delivery"),
    "user": os.environ.get("DB_USER", "food"),
    "password": os.environ.get("DB_PASSWORD", "")
}

def get_db_connection():
    return psycopg2.connect(cursor_factory=psycopg2.extras.RealDictCursor, **DB_CONFIG)

def init_db():
    conn = None
    for _ in range(30):
        try:
            conn = get_db_connection()
            break
        except psycopg2.OperationalError:
            print("Воркер ожидает PostgreSQL...", flush=True)
            time.sleep(2)
    if conn is None:
        raise RuntimeError("PostgreSQL недоступен")
    with conn, conn.cursor() as cur:
        cur.execute('''
            CREATE TABLE IF NOT EXISTS orders (
                id SERIAL PRIMARY KEY,
                customer_name TEXT NOT NULL,
                customer_phone TEXT NOT NULL,
                customer_address TEXT NOT NULL,
                order_items TEXT NOT NULL,
                total_price INTEGER NOT NULL,
                comments TEXT,
                status TEXT DEFAULT 'Новый',
                order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
    conn.close()

def callback(ch, method, properties, body):
    order = json.loads(body)
    print(f"Получен заказ от {order['customer_name']}. Обработка...", flush=True)
    
    # Имитируем работу кухни / обработки заказа
    time.sleep(3)

    try:
        conn = get_db_connection()
        with conn, conn.cursor() as cur:
            cur.execute('''
                INSERT INTO orders (customer_name, customer_phone, customer_address,
                                    order_items, total_price, comments)
                VALUES (%s, %s, %s, %s, %s, %s)
            ''', (
                order['customer_name'], 
                order['customer_phone'], 
                order['customer_address'],
                order['order_items'], 
                order['total_price'], 
                order['comments']
            ))
        conn.close()
        print(f"Заказ успешно сохранен в БД!", flush=True)
        # Подтверждаем сообщение брокеру
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception as e:
        print(f"Ошибка сохранения заказа в БД: {e}", flush=True)
        # Возвращаем сообщение в очередь при сбое
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)

def main():
    init_db()
    rabbitmq_host = os.environ.get("RABBITMQ_HOST", "rabbitmq")
    params = pika.ConnectionParameters(host=rabbitmq_host)
    
    while True:
        try:
            connection = pika.BlockingConnection(params)
            channel = connection.channel()
            channel.queue_declare(queue='order_queue', durable=True)
            channel.basic_qos(prefetch_count=1)
            channel.basic_consume(queue='order_queue', on_message_callback=callback)
            
            print("Воркер запущен и слушает очередь...", flush=True)
            channel.start_consuming()
        except Exception as e:
            print(f"Ошибка соединения с RabbitMQ: {e}. Переподключение через 5 секунд...", flush=True)
            time.sleep(5)

if __name__ == '__main__':
    main()