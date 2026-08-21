'use strict';

const mysql        = require('mysql2');
require('dotenv').config();

// ── Chatbot database: adminmicro (ip_products, ip_branches, history, bookings) ─
const pool = mysql.createPool({
    host:     process.env.CHATBOT_DB_HOST     || 'localhost',
    port:     parseInt(process.env.CHATBOT_DB_PORT || '3306', 10),
    user:     process.env.CHATBOT_DB_USER     || 'root',
    password: process.env.CHATBOT_DB_PASSWORD || '',
    database: process.env.CHATBOT_DB_NAME     || 'adminmicro',
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0
});

const promisePool = pool.promise();

async function getTableSchemas() {
    try {
        const [tables] = await promisePool.execute(
            'SELECT table_name FROM information_schema.tables WHERE table_schema = ?',
            [process.env.CHATBOT_DB_NAME || 'adminmicro']
        );
        const schemas = {};
        for (const table of tables) {
            const [columns] = await promisePool.execute(
                'SELECT column_name FROM information_schema.columns WHERE table_schema = ? AND table_name = ?',
                [process.env.CHATBOT_DB_NAME || 'adminmicro', table.table_name]
            );
            schemas[table.table_name] = columns;
        }
        return schemas;
    } catch (error) {
        return {};
    }
}

async function saveConversation(question, answer, contextUsed) {
    try {
        await promisePool.execute(
            'INSERT INTO conversation_history (question, answer, context_used) VALUES (?, ?, ?)',
            [question, answer, JSON.stringify(contextUsed)]
        );
    } catch (error) {
        console.error('Save error:', error);
    }
}

async function saveTestBooking(name, age, phone, documentUrl) {
    try {
        const [result] = await promisePool.execute(
            'INSERT INTO test_bookings (name, age, phone, document_url) VALUES (?, ?, ?, ?)',
            [name, Number(age), phone, documentUrl]
        );
        return { success: true, id: result.insertId };
    } catch (error) {
        console.error('❌ Booking save error:', error);
        return { success: false, error: error.message };
    }
}

module.exports = {
    getTableSchemas,
    saveConversation,
    saveTestBooking,
    pool: promisePool
};
