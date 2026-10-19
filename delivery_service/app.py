from flask import Flask, render_template, request, redirect, session, flash
import time
import os
import psycopg2
import psycopg2.extras
import pika
import json

DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "localhost"),
    "port": os.environ.get("DB_PORT", "5432"),
    "dbname": os.environ.get("DB_NAME", "food_delivery"),
    "user": os.environ.get("DB_USER", "food"),
    "password": os.environ.get("DB_PASSWORD", "")
}

app = Flask(__name__)
app.secret_key = 'super-secret-key'

ADMIN_USERNAME = "YOUR USERNAME"
ADMIN_PASSWORD = "YOUR PASSWORD"

def publish_order_to_queue(order_data):
    rabbitmq_host = os.environ.get("RABBITMQ_HOST", "rabbitmq")
    params = pika.ConnectionParameters(host=rabbitmq_host)
    connection = pika.BlockingConnection(params)
    channel = connection.channel()
    
    channel.queue_declare(queue='order_queue', durable=True)
    channel.basic_publish(
        exchange='',
        routing_key='order_queue',
        body=json.dumps(order_data),
        properties=pika.BasicProperties(delivery_mode=2)
    )
    connection.close()

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
    {"id": 12, "img": "lazania.png", "name": "Лазанья", "price": 350, "category": "Лазанья"}
]

@app.route('/')
def index():
    return render_template('index.html', menu=menu)

@app.route('/health')
def health():
    return {'status': 'ok'}, 200

@app.route('/add_to_cart/<int:item_id>')
def add_to_cart(item_id):
    if 'cart' not in session:
        session['cart'] = []

    cart = session['cart']
    cart.append(item_id)

    session['cart'] = cart
    return redirect('/')

@app.route('/remove_from_cart/<int:item_id>')
def remove_from_cart(item_id):
    if 'cart' in session:
        cart = session['cart']
        
        if item_id in cart:
            cart.remove(item_id)

        session['cart'] = cart

    return redirect('/cart')

@app.route('/cart')
def cart():
    cart_items = []
    total = 0
    if 'cart' in session:
        for item_id in session['cart']:
            item = next((x for x in menu if x['id'] == item_id), None)
            if item:
                cart_items.append(item)
                total += item['price']
    return render_template('cart.html', items=cart_items, total=total)

@app.route('/order')
def order():
    return render_template('order.html')

@app.route('/place_order', methods=['POST'])
def place_order():
    name = request.form['name']
    phone = request.form['phone']
    address = request.form['address']
    comments = request.form.get('comments', '')
    
    cart_items_names = []
    total = 0
    if 'cart' in session:
        for item_id in session['cart']:
            item = next((x for x in menu if x['id'] == item_id), None)
            if item:
                cart_items_names.append(item['name'])
                total += item['price']

    order_data = {
        "customer_name": name,
        "customer_phone": phone,
        "customer_address": address,
        "order_items": ', '.join(cart_items_names),
        "total_price": total,
        "comments": comments,
        "items_list": cart_items_names
    }

    try:
        publish_order_to_queue(order_data)
    except Exception as e:
        print(f"Ошибка отправки в RabbitMQ: {e}", flush=True)
        flash('Ошибка при оформлении заказа. Попробуйте позже.', 'danger')
        return redirect('/')
    
    session.pop('cart', None)
    flash('Заказ успешно принят в обработку!', 'success')
    return redirect('/')

@app.route('/admin')
def admin():
    if not session.get('admin'):
        return redirect('/login')
        
    conn = get_db_connection()
    with conn.cursor() as cur:
        cur.execute('SELECT * FROM orders ORDER BY order_date DESC')
        orders = cur.fetchall()
    conn.close()
    return render_template('admin.html', orders=orders)

@app.route('/update_status/<int:order_id>/<status>')
def update_status(order_id, status):
    conn = get_db_connection()
    with conn, conn.cursor() as cur:
        cur.execute('UPDATE orders SET status = %s WHERE id = %s', (status, order_id))
    conn.close() 


@app.route('/login', methods=['GET', 'POST'])
def login():
    error = None
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        if username == ADMIN_USERNAME and password == ADMIN_PASSWORD:
            session['admin'] = True
            return redirect('/admin')
        else:
            error = 'Неверный логин или пароль'
    return render_template('login.html', error=error)

@app.route('/logout')
def logout():
    session.pop('admin', None)
    return redirect('/')

init_db()
if __name__ == '__main__':
    app.run(host="0.0.0.0", port=8080)