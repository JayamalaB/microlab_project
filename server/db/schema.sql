-- Run this on your MySQL server (103.91.186.251) as root/admin
-- Creates the ai_chat database, user, and all tables needed by the chatbot

CREATE DATABASE IF NOT EXISTS ai_chat CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'ai_chat'@'%' IDENTIFIED BY 'ai_chat_microlab';
GRANT ALL PRIVILEGES ON ai_chat.* TO 'ai_chat'@'%';
FLUSH PRIVILEGES;

USE ai_chat;

CREATE TABLE IF NOT EXISTS products (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(200)   NOT NULL,
  description TEXT,
  price       DECIMAL(10,2)  NOT NULL DEFAULT 0,
  category    VARCHAR(100),
  stock       INT            NOT NULL DEFAULT 0,
  created_at  TIMESTAMP      DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS customers (
  id               INT AUTO_INCREMENT PRIMARY KEY,
  name             VARCHAR(200)  NOT NULL,
  email            VARCHAR(200),
  city             VARCHAR(100),
  membership_level ENUM('Silver','Gold','Platinum') DEFAULT 'Silver',
  created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS orders (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  customer_id INT            NOT NULL,
  order_date  DATETIME       DEFAULT CURRENT_TIMESTAMP,
  total_amount DECIMAL(10,2) NOT NULL DEFAULT 0,
  status      ENUM('Processing','Shipped','Delivered') DEFAULT 'Processing',
  FOREIGN KEY (customer_id) REFERENCES customers(id)
);

CREATE TABLE IF NOT EXISTS order_items (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  order_id   INT            NOT NULL,
  product_id INT            NOT NULL,
  quantity   INT            NOT NULL DEFAULT 1,
  price      DECIMAL(10,2)  NOT NULL DEFAULT 0,
  FOREIGN KEY (order_id)   REFERENCES orders(id),
  FOREIGN KEY (product_id) REFERENCES products(id)
);

CREATE TABLE IF NOT EXISTS inventory (
  id                 INT AUTO_INCREMENT PRIMARY KEY,
  product_id         INT          NOT NULL,
  warehouse_location VARCHAR(100) NOT NULL,
  quantity           INT          NOT NULL DEFAULT 0,
  last_restocked     DATE,
  FOREIGN KEY (product_id) REFERENCES products(id)
);

CREATE TABLE IF NOT EXISTS conversation_history (
  id           INT AUTO_INCREMENT PRIMARY KEY,
  question     TEXT,
  answer       TEXT,
  context_used JSON,
  created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS test_bookings (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  name       VARCHAR(200) NOT NULL,
  age        INT,
  phone      VARCHAR(20),
  package    VARCHAR(200),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Sample data so "My Orders" queries return results
INSERT INTO products (name, description, price, category, stock) VALUES
  ('Laptop Pro 15',   '15-inch performance laptop', 75000.00, 'Electronics',  12),
  ('Wireless Mouse',  'Ergonomic wireless mouse',    1500.00, 'Accessories',   50),
  ('USB-C Hub',       '7-in-1 USB-C hub',            2500.00, 'Accessories',   30),
  ('4K Monitor',      '27-inch 4K IPS display',     35000.00, 'Electronics',    8),
  ('Mechanical Keyboard', 'TKL mechanical keyboard', 8000.00, 'Electronics',  20),
  ('Noise-cancelling Headphones', 'Over-ear ANC',   12000.00, 'Electronics',  15);

INSERT INTO customers (name, email, city, membership_level) VALUES
  ('Arjun Sharma',  'arjun@example.com',  'Chennai',   'Gold'),
  ('Priya Nair',    'priya@example.com',  'Bangalore', 'Platinum'),
  ('Ravi Kumar',    'ravi@example.com',   'Mumbai',    'Silver'),
  ('Sneha Pillai',  'sneha@example.com',  'Chennai',   'Gold'),
  ('Mohan Das',     'mohan@example.com',  'Delhi',     'Silver');

INSERT INTO orders (customer_id, order_date, total_amount, status) VALUES
  (1, '2025-05-10', 76500.00, 'Delivered'),
  (2, '2025-05-15', 47000.00, 'Shipped'),
  (3, '2025-05-20',  4000.00, 'Processing'),
  (4, '2025-06-01', 12000.00, 'Delivered'),
  (1, '2025-06-10',  8000.00, 'Shipped');

INSERT INTO order_items (order_id, product_id, quantity, price) VALUES
  (1, 1, 1, 75000.00), (1, 2, 1, 1500.00),
  (2, 4, 1, 35000.00), (2, 5, 1, 8000.00), (2, 3, 1, 2500.00), (2, 6, 1, 1500.00),
  (3, 2, 1, 1500.00),  (3, 3, 1, 2500.00),
  (4, 6, 1, 12000.00),
  (5, 5, 1, 8000.00);

INSERT INTO inventory (product_id, warehouse_location, quantity, last_restocked) VALUES
  (1, 'Warehouse A', 5,  '2025-05-01'),
  (2, 'Warehouse B', 30, '2025-05-10'),
  (3, 'Warehouse B', 20, '2025-05-15'),
  (4, 'Warehouse A', 4,  '2025-04-20'),
  (5, 'Warehouse C', 15, '2025-06-01'),
  (6, 'Warehouse C', 10, '2025-05-28');
