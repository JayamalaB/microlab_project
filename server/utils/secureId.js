const crypto = require('crypto');
const https  = require('https');
const http   = require('http');
const { getSecret, refreshSecret } = require('../services/secretCache');
const { logAsmx } = require('../services/asmxLogger');

function buildSecureId(mobile_no, user_type, timestamp, secret) {
  const message = `${mobile_no}|${user_type}|${timestamp}`;
  return crypto
    .createHmac('sha256', secret)
    .update(message)
    .digest('hex');
}

function _isSignatureError(parsed) {
  if (typeof parsed === 'number') return parsed === 401 || parsed === 403;
  const msg = (parsed?.msg ?? parsed?.message ?? '').toLowerCase();
  return msg.includes('sign') || msg.includes('secret') ||
         msg.includes('unauthor') || msg.includes('invalid') || msg.includes('auth');
}

function _postForm(url, payload, timeoutMs = 5000) {
  return new Promise((resolve) => {
    try {
      const parsedUrl = new URL(url);
      const lib = parsedUrl.protocol === 'https:' ? https : http;
      const options = {
        hostname: parsedUrl.hostname,
        port:     parsedUrl.port || (parsedUrl.protocol === 'https:' ? 443 : 80),
        path:     parsedUrl.pathname + parsedUrl.search,
        method:   'POST',
        headers:  {
          'Content-Type':   'application/x-www-form-urlencoded',
          'Content-Length': Buffer.byteLength(payload),
        },
      };
      const req = lib.request(options, (res) => {
        let body = '';
        res.on('data', c => body += c);
        res.on('end', () => {
          try {
            const xmlMatch = /<string[^>]*>([\s\S]*?)<\/string>/.exec(body);
            const parsed = JSON.parse(xmlMatch ? xmlMatch[1] : body);
            console.log(`[clientServer] status ${res.statusCode} | response: ${body}`);
            resolve({ result: parsed, httpStatus: res.statusCode });
          } catch {
            console.error('[clientServer] invalid response:', body);
            resolve({ result: null, httpStatus: res.statusCode });
          }
        });
      });
      req.on('error', (err) => { console.error('[clientServer] request failed:', err.message); resolve({ result: null, httpStatus: null }); });
      req.setTimeout(timeoutMs, () => { req.destroy(); console.warn('[clientServer] request timed out'); resolve({ result: null, httpStatus: null }); });
      req.write(payload);
      req.end();
    } catch (err) {
      console.error('[clientServer] error:', err.message);
      resolve({ result: null, httpStatus: null });
    }
  });
}

async function checkClientUser(mobile_no, user_type) {
  const url = process.env.CLIENT_SERVER_URL;
  if (!url) return null;

  const secret    = await getSecret();
  const timestamp = Math.floor(Date.now() / 1000);
  const secure_id = buildSecureId(mobile_no, user_type, String(timestamp), secret);
  const payload   = new URLSearchParams({ mobile_no, user_type, timestamp: String(timestamp), secure_id }).toString();

  let { result, httpStatus } = await _postForm(url, payload);

  // Auto-recover on signature failure — refresh secret from DB and retry once
  if (result && _isSignatureError(result)) {
    console.warn('[clientServer] signature error on checkClientUser — refreshing secret and retrying');
    const newSecret    = await refreshSecret();
    const newSecureId  = buildSecureId(mobile_no, user_type, String(timestamp), newSecret);
    const retryPayload = new URLSearchParams({ mobile_no, user_type, timestamp: String(timestamp), secure_id: newSecureId }).toString();
    ({ result, httpStatus } = await _postForm(url, retryPayload));
  }

  await logAsmx('UserLoginCheck', {
    mobileNo: mobile_no,
    request:  { mobile_no, user_type, timestamp },
    response: result,
    httpStatus,
    success:  result != null && !_isSignatureError(result),
    errorMessage: result == null ? 'no response' : _isSignatureError(result) ? 'signature error' : null,
  });

  return result;
}

async function fetchPatientData(mobile_no, user_type) {
  const url = process.env.CLIENT_PATIENT_URL;
  if (!url) return null;

  const secret    = await getSecret();
  const timestamp = Math.floor(Date.now() / 1000);
  const secure_id = buildSecureId(mobile_no, user_type, String(timestamp), secret);
  const payload   = new URLSearchParams({ mobile_no, user_type, timestamp: String(timestamp), secure_id }).toString();

  let { result } = await _postForm(url, payload);

  if (result && _isSignatureError(result)) {
    console.warn('[patientServer] signature error on fetchPatientData — refreshing secret and retrying');
    const newSecret    = await refreshSecret();
    const newSecureId  = buildSecureId(mobile_no, user_type, String(timestamp), newSecret);
    const retryPayload = new URLSearchParams({ mobile_no, user_type, timestamp: String(timestamp), secure_id: newSecureId }).toString();
    ({ result } = await _postForm(url, retryPayload));
  }

  return result;
}

module.exports = { buildSecureId, checkClientUser, fetchPatientData };
