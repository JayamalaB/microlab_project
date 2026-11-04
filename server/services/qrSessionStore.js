// In-memory store for active Razorpay QR payment sessions.
// qrId (qr_xxx) → { bookingId, amount, technicianId, paid, paymentId }
// Entries are created on QR creation and marked paid by the webhook handler.
// Sessions survive the payment window (minutes); a server restart during an
// active session is unlikely, and the customer can simply generate a new QR.
const sessions = new Map();
module.exports = { sessions };
