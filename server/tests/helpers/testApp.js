// Builds a minimal Express app mounting one real route file, for use with
// supertest. Uses the exact same base middleware server.js uses
// (cors + express.json), so the real route + real controller code under
// test runs unmodified — this app just leaves out everything unrelated to
// HTTP routing (Socket.IO, cron schedulers, Firebase init).
const express = require('express');
const cors    = require('cors');

function buildTestApp(mountPath, router) {
  const app = express();
  app.use(cors());
  app.use(express.json());
  app.use(mountPath, router);
  return app;
}

module.exports = { buildTestApp };
