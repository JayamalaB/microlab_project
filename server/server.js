const express = require('express');
const cors    = require('cors');
const path    = require('path');
const http = require('http');
const { Server } = require('socket.io');
const bookingSocket = require('./socket/bookingSocket');
const bookingController = require('./controllers/bookingController');
const settings = require('./config/settings');
require('dotenv').config();

const app = express();
const { init: initKnowledge, reloadQA } = require('./services/knowledgeService');
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

// Serve banner images at /banners/<filename>
app.use('/banners', express.static(path.join(__dirname, 'banners')));
app.use('/uploads', express.static(path.join(__dirname, 'uploads')));

// Routes
app.use('/api/auth',         require('./routes/auth'));
app.use('/api/chat',         require('./routes/chat'));
app.use(require('./routes/voice'));  // /transcribe  /speak  /speak-multi  /speak-stream
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
  res.json({ success: true, message: 'MicroLab API running' });
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

// Hot-reload FAQ without restarting
app.post('/api/reload-qa', (req, res) => {
  const result = reloadQA();
  res.json({ success: true, ...result });
});

const PORT = process.env.PORT || 3000;

async function start() {
  await settings.init();
  await initKnowledge();
  httpServer.listen(PORT, () => {
    console.log(`🚀 MicroLab server running on http://localhost:${PORT}`);
    console.log(`🎙️  Sarvam API key: ${process.env.SARVAM_API_KEY ? '✓ loaded' : '✗ MISSING — voice will fail'}`);
  });
}

start();
