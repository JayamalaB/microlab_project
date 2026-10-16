'use strict';

// Last line of defence for error replies sent to the apps. Every 5xx JSON
// reply leaves without internal details — database messages, SQL, error
// codes like ER_BAD_FIELD_ERROR, stack-ish text — and with a message a
// customer or technician can read. The original reply is written to the
// server log first, so nothing is lost for debugging.
//
// A 5xx reply keeps its own message only when it carries an app error code
// (UPPER_SNAKE_CASE with at least one underscore, e.g. RATE_NOT_FOUND,
// REGISTRY_UNAVAILABLE) — those messages are written for users on purpose.
// 4xx replies are untouched apart from removing the internal-detail fields.

const FRIENDLY_SERVER_ERROR = 'Something went wrong on our side. Please try again in a moment.';

// Fields that only ever carry internal detail.
const INTERNAL_FIELDS = ['detail', 'details', 'debug', 'sqlState', 'sql', 'stack'];

function _isAppErrorCode(code) {
  return typeof code === 'string' && /^[A-Z]+(_[A-Z]+)+$/.test(code) && !code.startsWith('ER_');
}

function safeErrorResponse(req, res, next) {
  const originalJson = res.json.bind(res);

  res.json = (body) => {
    if (!body || typeof body !== 'object' || Array.isArray(body) || body.success !== false) {
      return originalJson(body);
    }

    const status   = res.statusCode;
    const hadInternal = INTERNAL_FIELDS.some((f) => body[f] !== undefined);
    if (status < 500 && !hadInternal) return originalJson(body);

    const safe = { ...body };
    for (const f of INTERNAL_FIELDS) delete safe[f];

    if (status >= 500) {
      if (!_isAppErrorCode(safe.code)) {
        delete safe.code;
        safe.message = FRIENDLY_SERVER_ERROR;
        if (typeof safe.error === 'string') safe.error = FRIENDLY_SERVER_ERROR;
      }
      console.error(`[safeErrorResponse] ${status} ${req.method} ${req.originalUrl} — original reply: ${JSON.stringify(body)}`);
    }

    return originalJson(safe);
  };

  next();
}

module.exports = safeErrorResponse;
module.exports.FRIENDLY_SERVER_ERROR = FRIENDLY_SERVER_ERROR;
