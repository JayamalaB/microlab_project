// adminHmacAuth.js — reusable HMAC-SHA256 admin-authentication middleware.
//
// Separate from server/middleware/adminAuth.js, which stays untouched: that
// file signs `bookingId|timestamp` for the booking-admin routes, and the
// external CodeIgniter portal already depends on that exact shape.
//
// ── Signing contract ────────────────────────────────────────────────────
//   signature = hex( HMAC-SHA256( secret, `${METHOD}|${PATH}|${TIMESTAMP}|${BODYHASH}` ) )
//
//   METHOD    — req.method, uppercased (e.g. "POST")
//   PATH      — req.originalUrl up to (not including) any "?". originalUrl
//               is the URL exactly as the client sent it, independent of
//               how routers are mounted internally. Routes using this
//               middleware should reject query strings entirely (they are
//               not covered by the signature).
//   TIMESTAMP — the X-Admin-Timestamp header verbatim; must match
//               ^\d{1,12}$ (unix seconds) and be within ±300s of now.
//   BODYHASH  — lowercase hex SHA-256 of the RAW request body bytes, exactly
//               as received (empty body → SHA-256 of zero bytes). Hashing
//               raw bytes rather than re-serialized JSON means the client
//               never has to reproduce any JSON canonicalization rules.
//
// Raw bytes come from rawBodyCapture() below, which must run before this
// middleware and before any other body parser has consumed the stream. If
// req.rawBody is missing the request is refused (fail closed) — a missing
// raw body must never be treated as "empty body".
'use strict';
const crypto  = require('crypto');
const express = require('express');

const REPLAY_WINDOW_SECONDS = 300;
const TIMESTAMP_RE = /^\d{1,12}$/;
const SIGNATURE_RE = /^[0-9a-fA-F]{64}$/;

// Captures the request body as raw bytes into req.rawBody (a Buffer; empty
// when there is no body). Any content type is captured, so no body can
// bypass hashing. Compressed bodies are refused (inflate: false), so the
// bytes hashed are always the bytes the client signed.
function rawBodyCapture({ limit = '32kb' } = {}) {
  const raw = express.raw({ type: () => true, limit, inflate: false });

  return function captureRawBody(req, res, next) {
    if (req.body !== undefined) {
      // Another parser already consumed the body — the raw bytes are gone.
      console.error('[adminHmacAuth] rawBodyCapture mounted after another body parser');
      return res.status(500).json({ success: false, message: 'Server misconfiguration' });
    }
    raw(req, res, (err) => {
      if (err) return next(err);
      req.rawBody = Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);
      req.body = undefined;
      next();
    });
  };
}

function _buildCanonicalPayload(req) {
  const method    = req.method.toUpperCase();
  const path      = req.originalUrl.split('?')[0];
  const timestamp = req.headers['x-admin-timestamp'];
  const bodyHash  = crypto.createHash('sha256').update(req.rawBody).digest('hex');
  return `${method}|${path}|${timestamp}|${bodyHash}`;
}

// createAdminHmacAuth({ secretEnvVar }) → an Express middleware that
// verifies the signature using process.env[secretEnvVar].
function createAdminHmacAuth({ secretEnvVar }) {
  if (!secretEnvVar) {
    throw new Error('createAdminHmacAuth requires a secretEnvVar name');
  }

  return function adminHmacAuth(req, res, next) {
    // Logs use the path only — never the query string, headers, or body.
    const path = req.originalUrl.split('?')[0];

    const secret = process.env[secretEnvVar];
    if (!secret) {
      console.error(`[adminHmacAuth] ${secretEnvVar} not set in .env`);
      return res.status(500).json({ success: false, message: 'Server misconfiguration' });
    }
    if (!Buffer.isBuffer(req.rawBody)) {
      console.error('[adminHmacAuth] req.rawBody missing — rawBodyCapture() must run first');
      return res.status(500).json({ success: false, message: 'Server misconfiguration' });
    }

    const signature = req.headers['x-admin-signature'];
    const timestamp = req.headers['x-admin-timestamp'];

    if (!signature || !timestamp) {
      console.warn(`[adminHmacAuth] REJECTED — missing headers  path=${path}  ip=${req.ip}`);
      return res.status(403).json({ success: false, message: 'Admin credentials missing' });
    }

    const now = Math.floor(Date.now() / 1000);
    if (!TIMESTAMP_RE.test(timestamp) || Math.abs(now - Number(timestamp)) > REPLAY_WINDOW_SECONDS) {
      console.warn(`[adminHmacAuth] REJECTED — timestamp invalid/expired  path=${path}  ip=${req.ip}`);
      return res.status(403).json({ success: false, message: 'Request timestamp expired' });
    }

    let match = false;
    if (SIGNATURE_RE.test(signature)) {
      const expected = crypto.createHmac('sha256', secret).update(_buildCanonicalPayload(req)).digest('hex');
      try {
        match = crypto.timingSafeEqual(Buffer.from(signature, 'hex'), Buffer.from(expected, 'hex'));
      } catch {
        match = false;
      }
    }

    if (!match) {
      console.warn(`[adminHmacAuth] REJECTED — signature mismatch  method=${req.method}  path=${path}  ip=${req.ip}`);
      return res.status(403).json({ success: false, message: 'Invalid admin signature' });
    }

    console.log(`[adminHmacAuth] OK  method=${req.method}  path=${path}  ip=${req.ip}`);
    next();
  };
}

module.exports = { createAdminHmacAuth, rawBodyCapture, _buildCanonicalPayload };
