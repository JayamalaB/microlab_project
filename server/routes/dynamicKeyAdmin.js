// Dynamic Key Admin API — /api/admin/dynamic-keys
//
// Must be mounted in server.js BEFORE the global express.json(), so the raw
// request bytes are still available for the HMAC body hash (same reason the
// Razorpay webhook is mounted early). Order of the middleware below:
//   1. reject any query string (never signed, and must never carry values)
//   2. capture raw body bytes
//   3. verify HMAC signature (DYNAMIC_KEY_ADMIN_HMAC_SECRET)
//   4. parse the already-verified raw bytes as JSON
//   5. handlers, then JSON-only 404 / error responses for this router
'use strict';
const express = require('express');
const router  = express.Router();
const { createAdminHmacAuth, rawBodyCapture } = require('../middleware/adminHmacAuth');
const { listKeys, getKey, setKey } = require('../controllers/dynamicKeyAdminController');

const RAW_BODY_LIMIT = '32kb';

function rejectQueryString(req, res, next) {
  if (req.originalUrl.includes('?')) {
    // Deliberately not logging the URL: the query string is exactly where a
    // misbehaving client might have put a secret.
    return res.status(400).json({ success: false, message: 'Query parameters are not allowed' });
  }
  next();
}

const utf8 = new TextDecoder('utf-8', { fatal: true });

// Parses req.rawBody (already covered by the signature) into req.body.
function parseJsonBody(req, res, next) {
  if (req.rawBody.length === 0) {
    req.body = {};
    return next();
  }
  if (!req.is('application/json')) {
    return res.status(400).json({ success: false, message: 'Content-Type must be application/json' });
  }
  let parsed;
  try {
    parsed = JSON.parse(utf8.decode(req.rawBody));
  } catch {
    return res.status(400).json({ success: false, message: 'Malformed JSON body' });
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return res.status(400).json({ success: false, message: 'Request body must be a JSON object' });
  }
  req.body = parsed;
  next();
}

router.use(rejectQueryString);
router.use(rawBodyCapture({ limit: RAW_BODY_LIMIT }));
router.use(createAdminHmacAuth({ secretEnvVar: 'DYNAMIC_KEY_ADMIN_HMAC_SECRET' }));
router.use(parseJsonBody);

router.get('/', listKeys);
router.get('/:keyName', getKey);
router.post('/:keyName', setKey);

// Anything else under this prefix gets JSON, not Express's default HTML.
router.use((req, res) => res.status(404).json({ success: false, message: 'Not found' }));

// Errors from the raw-body parser (oversized, compressed) — JSON, fixed
// messages, never the error's own text.
// eslint-disable-next-line no-unused-vars
router.use((err, req, res, next) => {
  if (err.type === 'entity.too.large') {
    return res.status(413).json({ success: false, message: 'Request body too large' });
  }
  if (err.type === 'encoding.unsupported') {
    return res.status(415).json({ success: false, message: 'Compressed request bodies are not supported' });
  }
  const status = Number.isInteger(err.status) && err.status >= 400 && err.status < 500 ? err.status : 500;
  if (status === 500) console.error(`[dynamicKeyAdmin] unhandled error  type=${err.type ?? err.name}`);
  res.status(status).json({ success: false, message: status === 500 ? 'Server error' : 'Bad request' });
});

module.exports = router;
