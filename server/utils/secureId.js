const crypto = require('crypto');
const https  = require('https');
const http   = require('http');

function buildSecureId(mobile_no, user_type, timestamp) {
  const message = `${mobile_no}|${user_type}|${timestamp}`;
  return crypto
    .createHmac('sha256', process.env.CLIENT_SERVER_SECRET)
    .update(message)
    .digest('hex');
}

/**
 * POST to client server and return parsed response.
 * Resolves with { status, msg } or null on error/timeout.
 */
function checkClientUser(mobile_no, user_type) {
  const url = process.env.CLIENT_SERVER_URL;
  if (!url || !process.env.CLIENT_SERVER_SECRET) return Promise.resolve(null);

  const timestamp = Math.floor(Date.now() / 1000);
  const secure_id = buildSecureId(mobile_no, user_type, timestamp);
  const payload   = JSON.stringify({ mobile_no, user_type, timestamp, secure_id });

  return new Promise((resolve) => {
    try {
      const parsedUrl = new URL(url);
      const lib = parsedUrl.protocol === 'https:' ? https : http;
      const options = {
        hostname: parsedUrl.hostname,
        port    : parsedUrl.port || (parsedUrl.protocol === 'https:' ? 443 : 80),
        path    : parsedUrl.pathname + parsedUrl.search,
        method  : 'POST',
        headers : {
          'Content-Type'  : 'application/json',
          'Content-Length': Buffer.byteLength(payload),
        },
      };

      const req = lib.request(options, (res) => {
        let body = '';
        res.on('data', (chunk) => (body += chunk));
        res.on('end', () => {
          try {
            const parsed = JSON.parse(body);
            console.log(`[clientServer] status ${res.statusCode} | response: ${body}`);
            resolve(parsed);
          } catch {
            console.error('[clientServer] invalid JSON response:', body);
            resolve(null);
          }
        });
      });

      req.on('error', (err) => {
        console.error('[clientServer] request failed:', err.message);
        resolve(null);
      });

      req.setTimeout(5000, () => {
        req.destroy();
        console.warn('[clientServer] request timed out');
        resolve(null);
      });

      req.write(payload);
      req.end();
    } catch (err) {
      console.error('[clientServer] error:', err.message);
      resolve(null);
    }
  });
}

/**
 * POST to client patient endpoint and return parsed response.
 * Resolves with { status, patient: [] } or null on error/timeout.
 */
function fetchPatientData(mobile_no, user_type) {
  const url = process.env.CLIENT_PATIENT_URL;
  if (!url || !process.env.CLIENT_SERVER_SECRET) return Promise.resolve(null);

  const timestamp = Math.floor(Date.now() / 1000);
  const secure_id = buildSecureId(mobile_no, user_type, timestamp);
  const payload   = JSON.stringify({ mobile_no, user_type, timestamp, secure_id });

  return new Promise((resolve) => {
    try {
      const parsedUrl = new URL(url);
      const lib = parsedUrl.protocol === 'https:' ? https : http;
      const options = {
        hostname: parsedUrl.hostname,
        port    : parsedUrl.port || (parsedUrl.protocol === 'https:' ? 443 : 80),
        path    : parsedUrl.pathname + parsedUrl.search,
        method  : 'POST',
        headers : {
          'Content-Type'  : 'application/json',
          'Content-Length': Buffer.byteLength(payload),
        },
      };

      const req = lib.request(options, (res) => {
        let body = '';
        res.on('data', (chunk) => (body += chunk));
        res.on('end', () => {
          try {
            resolve(JSON.parse(body));
          } catch {
            console.error('[patientServer] invalid JSON:', body);
            resolve(null);
          }
        });
      });

      req.on('error', (err) => {
        console.error('[patientServer] request failed:', err.message);
        resolve(null);
      });

      req.setTimeout(5000, () => {
        req.destroy();
        console.warn('[patientServer] request timed out');
        resolve(null);
      });

      req.write(payload);
      req.end();
    } catch (err) {
      console.error('[patientServer] error:', err.message);
      resolve(null);
    }
  });
}

module.exports = { buildSecureId, checkClientUser, fetchPatientData };
