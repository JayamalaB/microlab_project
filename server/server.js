const express = require('express');
const cors = require('cors');
const http = require('http');
const { Server } = require('socket.io');
const bookingSocket = require('./socket/bookingSocket');
require('dotenv').config();

const app = express();
const httpServer = http.createServer(app);

const io = new Server(httpServer, {
  cors: { origin: '*' },
});

io.on('connection', (socket) => {
  bookingSocket(io, socket);
});

app.use(cors());
app.use(express.json());

// Routes
app.use('/api/auth', require('./routes/auth'));

app.get('/', (req, res) => {
  res.json({ success: true, message: 'MediCollect API running' });
});

const PORT = process.env.PORT || 3000;
httpServer.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
