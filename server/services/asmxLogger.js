const db = require('../config/db');

/**
 * Logs one ASMX call to ip_asmx_logs. Never throws — logging must not break callers.
 *
 * @param {string} endpoint  - 'NewPatientNewBooking' | 'BookingCancellation' | etc.
 * @param {object} opts
 * @param {string|null}  opts.bookingRef
 * @param {number|null}  opts.bookingId
 * @param {string|null}  opts.mobileNo
 * @param {object|null}  opts.request      - request payload sent (secure_id excluded)
 * @param {object|null}  opts.response     - parsed response received
 * @param {number|null}  opts.httpStatus
 * @param {boolean}      opts.success
 * @param {string|null}  opts.errorMessage
 */
async function logAsmx(endpoint, {
  bookingRef   = null,
  bookingId    = null,
  mobileNo     = null,
  request      = null,
  response     = null,
  httpStatus   = null,
  success      = false,
  errorMessage = null,
} = {}) {
  try {
    // Strip secure_id from logged request — it is a derived auth token, not debug-useful
    let logRequest = request;
    if (logRequest && typeof logRequest === 'object' && 'secure_id' in logRequest) {
      const { secure_id: _s, ...rest } = logRequest;
      logRequest = rest;
    }
    await db.execute(
      `INSERT INTO ip_asmx_logs
         (endpoint, booking_ref, booking_id, mobile_no,
          request_payload, response_payload, http_status, success, error_message)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        endpoint,
        bookingRef,
        bookingId,
        mobileNo,
        logRequest  != null ? JSON.stringify(logRequest)  : null,
        response    != null ? JSON.stringify(response)    : null,
        httpStatus,
        success ? 1 : 0,
        errorMessage ? String(errorMessage).slice(0, 500) : null,
      ]
    );
  } catch (err) {
    console.error('[asmxLogger] insert failed:', err.message);
  }
}

module.exports = { logAsmx };
