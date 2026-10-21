import json
import os
import time

import pika
import psycopg2
import psycopg2.extras


DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "postgres"),
    "port": os.environ.get("DB_PORT", "5432"),
    "dbname": os.environ.get("DB_NAME", "food_delivery"),
    "user": os.environ.get("DB_USER", "food"),
    "password": os.environ.get("DB_PASSWORD", ""),
    "connect_timeout": 5,
}

RABBITMQ_HOST = os.environ.get("RABBITMQ_HOST", "rabbitmq")
RABBITMQ_PORT = int(os.environ.get("RABBITMQ_PORT", "5672"))
RABBITMQ_USER = os.environ.get("RABBITMQ_USER", "guest")
RABBITMQ_PASSWORD = os.environ.get("RABBITMQ_PASSWORD", "guest")
RABBITMQ_QUEUE = os.environ.get("RABBITMQ_QUEUE", "order_queue")


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
        cur.execute(
            """
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
            """
        )
    conn.close()


def rabbitmq_params():
    credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
    return pika.ConnectionParameters(
        host=RABBITMQ_HOST,
        port=RABBITMQ_PORT,
        credentials=credentials,
        heartbeat=600,
        blocked_connection_timeout=300,
        socket_timeout=5,
        stack_timeout=10,
    )


def callback(ch, method, properties, body):
    try:
        order = json.loads(body)
        required = ("customer_name", "customer_phone", "customer_address", "order_items", "total_price")
        missing = [field for field in required if field not in order]
        if missing:
            raise ValueError(f"нет полей: {', '.join(missing)}")
    except (json.JSONDecodeError, ValueError, TypeError) as exc:
        print(f"Некорректное сообщение в очереди: {exc}", flush=True)
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
        return

    print(f"Получен заказ от {order['customer_name']}. Обработка...", flush=True)
    time.sleep(3)

    try:
        conn = get_db_connection()
        try:
            with conn, conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO orders (customer_name, customer_phone, customer_address,
                                        order_items, total_price, comments)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    """,
                    (
                        order["customer_name"],
                        order["customer_phone"],
                        order["customer_address"],
                        order["order_items"],
                        order["total_price"],
                        order.get("comments", ""),
                    ),
                )
        finally:
            conn.close()
        print("Заказ успешно сохранён в БД!", flush=True)
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception as exc:
        print(f"Ошибка сохранения заказа в БД: {exc}", flush=True)
        time.sleep(2)
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)


def main():
    init_db()

    while True:
        try:
            connection = pika.BlockingConnection(rabbitmq_params())
            channel = connection.channel()
            channel.queue_declare(queue=RABBITMQ_QUEUE, durable=True)
            channel.basic_qos(prefetch_count=1)
            channel.basic_consume(queue=RABBITMQ_QUEUE, on_message_callback=callback)

            print("Воркер запущен и слушает очередь...", flush=True)
            channel.start_consuming()
        except KeyboardInterrupt:
            break
        except Exception as exc:
            print(f"Ошибка соединения с RabbitMQ: {exc}. Переподключение через 5 секунд...", flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
