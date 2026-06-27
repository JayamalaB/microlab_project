const express = require('express');
const cors    = require('cors');
const path    = require('path');
require('dotenv').config();

const app = express();
const cache = require('./services/cacheService');
const { init: initKnowledge, reloadQA } = require('./services/knowledgeService');
const { clearPageCache } = require('./rag/websiteReader');

app.use(cors());
app.use(express.json());

// Serve banner images at /banners/<filename>
app.use('/banners', express.static(path.join(__dirname, 'banners')));

// Routes
app.use('/api/auth', require('./routes/auth'));
app.use('/api/chat', require('./routes/chat'));
app.use(require('./routes/voice'));  // /transcribe  /speak  /speak-multi  /speak-stream

app.get('/', (req, res) => {
  res.json({ success: true, message: 'MicroLab API running' });
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok', cache: cache.isConnected ? 'redis' : 'disabled' });
});

// Hot-reload FAQ without restarting
app.post('/api/reload-qa', (req, res) => {
  const result = reloadQA();
  res.json({ success: true, ...result });
});

// Invalidate cached website pages (call after site update)
app.post('/api/clear-site-cache', async (req, res) => {
  await clearPageCache();
  res.json({ success: true, message: 'Website page cache cleared' });
});

// Flush Redis cache by pattern
app.delete('/api/cache', async (req, res) => {
  const { pattern = '*' } = req.query;
  await cache.flush(pattern);
  res.json({ success: true, message: `Cache flushed (pattern: ${pattern})` });
});

const PORT = process.env.PORT || 3000;

async function start() {
  await cache.connect();
  await initKnowledge();
  app.listen(PORT, () => {
    console.log(`🚀 MicroLab server running on http://localhost:${PORT}`);
    console.log(`🎙️  Sarvam API key: ${process.env.SARVAM_API_KEY ? '✓ loaded' : '✗ MISSING — voice will fail'}`);
  });
}

start();
