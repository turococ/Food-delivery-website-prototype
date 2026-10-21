from flask import Flask, render_template, request, redirect, session, flash
import hmac
import json
import os
import time

import psycopg2
import psycopg2.extras
import pika


DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "localhost"),
    "port": os.environ.get("DB_PORT", "5432"),
    "dbname": os.environ.get("DB_NAME", "food_delivery"),
    "user": os.environ.get("DB_USER", "food"),
    "password": os.environ.get("DB_PASSWORD", ""),
    "connect_timeout": 5,
}

RABBITMQ_HOST = os.environ.get("RABBITMQ_HOST", "localhost")
RABBITMQ_PORT = int(os.environ.get("RABBITMQ_PORT", "5672"))
RABBITMQ_USER = os.environ.get("RABBITMQ_USER", "guest")
RABBITMQ_PASSWORD = os.environ.get("RABBITMQ_PASSWORD", "guest")
RABBITMQ_QUEUE = os.environ.get("RABBITMQ_QUEUE", "order_queue")

ORDER_STATUSES = ("Новый", "Готовится", "Доставка", "Выполнен")

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "dev-secret-change-me")
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
)

ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "admin")


def get_db_connection():
    return psycopg2.connect(cursor_factory=psycopg2.extras.RealDictCursor, **DB_CONFIG)


def init_db():
    conn = None
    for _ in range(30):
        try:
            conn = get_db_connection()
            break
        except psycopg2.OperationalError:
            print("Ожидание PostgreSQL...", flush=True)
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


def publish_order_to_queue(order_data):
    credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
    params = pika.ConnectionParameters(
        host=RABBITMQ_HOST,
        port=RABBITMQ_PORT,
        credentials=credentials,
        heartbeat=600,
        blocked_connection_timeout=300,
        socket_timeout=5,
        stack_timeout=10,
    )
    connection = pika.BlockingConnection(params)
    try:
        channel = connection.channel()
        channel.queue_declare(queue=RABBITMQ_QUEUE, durable=True)
        channel.basic_publish(
            exchange="",
            routing_key=RABBITMQ_QUEUE,
            body=json.dumps(order_data, ensure_ascii=False),
            properties=pika.BasicProperties(
                delivery_mode=2,
                content_type="application/json",
            ),
        )
    finally:
        connection.close()


menu = [
    {"id": 1, "img": "pizza-peperoni.jpg", "name": "Пепперони", "price": 450, "category": "Пицца"},
    {"id": 2, "img": "pizza-margarita.jpg", "name": "Маргарита", "price": 350, "category": "Пицца"},
    {"id": 3, "img": "pizza-bbq.jpg", "name": "Барбекю", "price": 350, "category": "Пицца"},
    {"id": 4, "img": "cesar.png", "name": "Цезарь", "price": 320, "category": "Салаты"},
    {"id": 5, "img": "salat-grecheskii.jpg", "name": "Греческий", "price": 280, "category": "Салаты"},
    {"id": 6, "img": "dobri-cola.png", "name": "Кола 0.5", "price": 100, "category": "Напитки"},
    {"id": 7, "img": "dobri-apesin.png", "name": "Сок апельсиновый", "price": 150, "category": "Напитки"},
    {"id": 8, "img": "pasta-karbonara.jpg", "name": "Паста Карбонара", "price": 350, "category": "Паста"},
    {"id": 9, "img": "pasta-boloniese.png", "name": "Паста Болоньезе", "price": 350, "category": "Паста"},
    {"id": 10, "img": "sup-minestrone.png", "name": "Минестроне", "price": 350, "category": "Суп"},
    {"id": 11, "img": "sup-strachatella.jpg", "name": "Страчателла", "price": 350, "category": "Суп"},
    {"id": 12, "img": "lazania.png", "name": "Лазанья", "price": 350, "category": "Лазанья"},
]


def find_menu_item(item_id):
    return next((item for item in menu if item["id"] == item_id), None)


def get_cart_items():
    cart_items = []
    total = 0
    for item_id in session.get("cart", []):
        item = find_menu_item(item_id)
        if item:
            cart_items.append(item)
            total += item["price"]
    return cart_items, total


@app.route("/")
def index():
    return render_template("index.html", menu=menu)


@app.route("/health")
def health():
    return {"status": "ok"}, 200


@app.route("/add_to_cart/<int:item_id>")
def add_to_cart(item_id):
    if find_menu_item(item_id) is None:
        flash("Блюдо не найдено", "danger")
        return redirect("/")

    cart = session.get("cart", [])
    cart.append(item_id)
    session["cart"] = cart
    return redirect("/")


@app.route("/remove_from_cart/<int:item_id>")
def remove_from_cart(item_id):
    cart = session.get("cart", [])
    if item_id in cart:
        cart.remove(item_id)
    session["cart"] = cart
    return redirect("/cart")


@app.route("/cart")
def cart():
    items, total = get_cart_items()
    return render_template("cart.html", items=items, total=total)


@app.route("/order")
def order():
    if not session.get("cart"):
        flash("Сначала добавьте блюда в корзину", "danger")
        return redirect("/cart")
    return render_template("order.html")


@app.route("/place_order", methods=["POST"])
def place_order():
    name = request.form.get("name", "").strip()
    phone = request.form.get("phone", "").strip()
    address = request.form.get("address", "").strip()
    comments = request.form.get("comments", "").strip()

    if not name or not phone or not address:
        flash("Заполните имя, телефон и адрес", "danger")
        return redirect("/order")

    cart_items, total = get_cart_items()
    if not cart_items:
        flash("Корзина пуста", "danger")
        return redirect("/cart")

    order_data = {
        "customer_name": name,
        "customer_phone": phone,
        "customer_address": address,
        "order_items": ", ".join(item["name"] for item in cart_items),
        "total_price": total,
        "comments": comments,
        "items_list": [item["name"] for item in cart_items],
    }

    try:
        publish_order_to_queue(order_data)
    except Exception as exc:
        print(f"Ошибка отправки в RabbitMQ: {exc}", flush=True)
        flash("Ошибка при оформлении заказа. Попробуйте позже.", "danger")
        return redirect("/order")

    session.pop("cart", None)
    flash("Заказ успешно принят в обработку!", "success")
    return redirect("/")


@app.route("/admin")
def admin():
    if not session.get("admin"):
        return redirect("/login")

    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM orders ORDER BY order_date DESC")
            orders = cur.fetchall()
    finally:
        conn.close()
    return render_template("admin.html", orders=orders, statuses=ORDER_STATUSES)


@app.route("/update_status/<int:order_id>", methods=["POST"])
def update_status(order_id):
    if not session.get("admin"):
        return redirect("/login")

    status = request.form.get("status", "")
    if status not in ORDER_STATUSES:
        flash("Недопустимый статус заказа", "danger")
        return redirect("/admin")

    conn = get_db_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute("UPDATE orders SET status = %s WHERE id = %s", (status, order_id))
        flash("Статус заказа обновлён", "success")
    finally:
        conn.close()
    return redirect("/admin")


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        username = request.form.get("username", "")
        password = request.form.get("password", "")
        if hmac.compare_digest(username.encode(), ADMIN_USERNAME.encode()) and hmac.compare_digest(
            password.encode(), ADMIN_PASSWORD.encode()
        ):
            session["admin"] = True
            return redirect("/admin")
        error = "Неверный логин или пароль"
    return render_template("login.html", error=error)


@app.route("/logout")
def logout():
    session.pop("admin", None)
    return redirect("/")


init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
