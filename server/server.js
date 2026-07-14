const express = require('express');
const cors = require('cors');
const http = require('http');
const { Server } = require('socket.io');
const bookingSocket = require('./socket/bookingSocket');
const bookingController = require('./controllers/bookingController');
const settings = require('./config/settings');
require('dotenv').config();

const app = express();
const httpServer = http.createServer(app);

const io = new Server(httpServer, {
  cors: { origin: '*' },
});

// Give bookingController a reference to io so REST updates can push to sockets
bookingController.setIo(io);

io.on('connection', (socket) => {
  bookingSocket(io, socket);
});

// Start scheduled dispatch cron (fires every minute)
require('./scheduler/dispatchScheduler')(io);

app.use(cors());
app.use(express.json());
app.use('/uploads', require('express').static(require('path').join(__dirname, 'uploads')));

// Routes
app.use('/api/auth',         require('./routes/auth'));
app.use('/api/tests',        require('./routes/tests'));
app.use('/api/bookings',     require('./routes/bookings'));
app.use('/api/technicians',  require('./routes/technicians'));
app.use('/api/branches',     require('./routes/branches'));
app.use('/api/packages',     require('./routes/packages'));
app.use('/api/patients',     require('./routes/patients'));
app.use('/api/slots',        require('./routes/slots'));
app.use('/api/upload',        require('./routes/upload'));
app.use('/api/prescriptions', require('./routes/prescriptions'));
app.use('/api/feedback',               require('./routes/feedback'));
app.use('/api/prescription-requests',  require('./routes/prescriptionRequests'));

app.get('/', (req, res) => {
  res.json({ success: true, message: 'MediCollect API running' });
});

const PORT = process.env.PORT || 3000;
settings.init().then(() => {
  httpServer.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT}`);
  });
});
