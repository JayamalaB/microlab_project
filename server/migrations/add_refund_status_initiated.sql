ALTER TABLE ip_bookings
MODIFY COLUMN refund_status ENUM('none', 'pending', 'initiated', 'processed') DEFAULT NULL;
