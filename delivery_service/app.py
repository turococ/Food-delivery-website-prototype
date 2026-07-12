from flask import Flask, render_template, request, redirect, session, url_for, Response, flash
from functools import wraps
import sqlite3

app = Flask(__name__)
app.secret_key = 'super-secret-key'

# Настройки админа
ADMIN_USERNAME = ""
ADMIN_PASSWORD = ""

# Подключение к БД
def get_db_connection():
    conn = sqlite3.connect('food_delivery.db')
    conn.row_factory = sqlite3.Row
    return conn

# Инициализация БД
def init_db():
    conn = get_db_connection()
    conn.execute('''
        CREATE TABLE IF NOT EXISTS orders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
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
    conn.commit()
    conn.close()

# Меню (заполните своими позициями)
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

# Маршруты
@app.route('/')
def index():
    return render_template('index.html', menu=menu)

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
@app.route('/place_order', methods=['POST'])
def place_order():
    name = request.form['name']
    phone = request.form['phone']
    address = request.form['address']
    comments = request.form.get('comments', '')
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cart_items = []
    total = 0
    if 'cart' in session:
        for item_id in session['cart']:
            item = next((x for x in menu if x['id'] == item_id), None)
            if item:
                cart_items.append(item['name'])
                total += item['price']
    
    if not cart_items:
        flash('Корзина пуста!', 'error')
        conn.close()
        return redirect('/cart')
    
    cursor.execute('''
        INSERT INTO orders (customer_name, customer_phone, customer_address, 
                          order_items, total_price, comments) 
        VALUES (?, ?, ?, ?, ?, ?)
    ''', (name, phone, address, ', '.join(cart_items), total, comments))
    
    order_id = cursor.lastrowid
    conn.commit()
    conn.close()
    
    session.pop('cart', None)
    flash(f'Заказ успешно оформлен!', 'success')
    return redirect('/')


@app.route('/admin')
def admin():
    if not session.get('admin'):
        return redirect('/login')

    conn = get_db_connection()
    orders = conn.execute('SELECT * FROM orders ORDER BY order_date DESC').fetchall()
    conn.close()
    return render_template('admin.html', orders=orders)


@app.route('/update_status/<int:order_id>/<status>')
def update_status(order_id, status):
    if not session.get('admin'):
        return redirect('/login')

    conn = get_db_connection()
    conn.execute('UPDATE orders SET status = ? WHERE id = ?', (status, order_id))
    conn.commit()
    conn.close()
    return redirect('/admin')


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

if __name__ == '__main__':
    init_db()
    app.run(debug=True)
