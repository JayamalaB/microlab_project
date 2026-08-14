const express = require('express');
const router = express.Router();
const bookingController = require('../controllers/bookingController');
const auth        = require('../middleware/auth');
const adminAuth   = require('../middleware/adminAuth');
const adminSecret = require('../middleware/adminSecret');

// POST /api/bookings — create booking (returns bookingId)
router.post('/', auth, bookingController.createBooking);

// POST /api/bookings/family — create multiple bookings sharing one visit slot
router.post('/family', auth, bookingController.createFamilyBooking);

// GET /api/bookings/mine — all bookings for the logged-in user (JWT)
router.get('/mine', auth, bookingController.getMyBookings);

// GET /api/bookings/patient/:patientId — patient booking history
router.get('/patient/:patientId', bookingController.getPatientBookings);

// GET /api/bookings/:bookingId — single booking detail
router.get('/:bookingId', bookingController.getBooking);

// GET /api/bookings/:bookingId/results — released test results for patient
router.get('/:bookingId/results', auth, bookingController.getBookingResults);

// GET /api/bookings/:bookingId/results/:resultId/proxy — stream report PDF via server (avoids CORS)
router.get('/:bookingId/results/:resultId/proxy', auth, bookingController.proxyReport);

// POST /api/bookings/:bookingId/results/:resultId/released — admin notifies result released (fires FCM push)
router.post('/:bookingId/results/:resultId/released', adminSecret, bookingController.releaseResult);

// GET  /api/bookings/:bookingId/items   — list booking test items
router.get('/:bookingId/items',                    auth, bookingController.getItems);
// GET  /api/bookings/:bookingId/linked-patients — additional patients added by technician
router.get('/:bookingId/linked-patients',          auth, bookingController.getLinkedPatients);
// POST /api/bookings/:bookingId/items   — add a test to a booking
router.post('/:bookingId/items',                   auth, bookingController.addItem);
// DELETE /api/bookings/:bookingId/items/:id — remove a test from a booking
router.delete('/:bookingId/items/:bookingItemId',  auth, bookingController.removeItem);
// PATCH /api/bookings/:bookingId/items/:bookingItemId/collected — technician checklist toggle
router.patch('/:bookingId/items/:bookingItemId/collected', auth, bookingController.setItemCollected);
// POST /api/bookings/:bookingId/collection-photo — technician's sample-collection proof photo
router.post('/:bookingId/collection-photo', auth, bookingController.saveCollectionProofPhoto);
// GET  /api/bookings/:bookingId/collection-photo — current proof photo (if any)
router.get('/:bookingId/collection-photo', auth, bookingController.getCollectionProofPhoto);

// POST /api/bookings/:bookingId/cancel — customer cancels a booking
router.post('/:bookingId/cancel', auth, bookingController.cancelBooking);

// POST /api/bookings/:bookingId/reschedule — customer reschedules date/slot
router.post('/:bookingId/reschedule', auth, bookingController.rescheduleBooking);

// POST /api/bookings/:bookingId/pay — pay a pending booking via Razorpay
router.post('/:bookingId/pay', auth, bookingController.payBooking);

// PUT /api/bookings/:bookingId/items — replace tests/packages on an existing booking
router.put('/:bookingId/items', auth, bookingController.updateBookingItems);

// PUT /api/bookings/:bookingId/lab-status — update lab pipeline stage (lab-side only)
router.put('/:bookingId/lab-status',    adminSecret, bookingController.updateLabStatus);

// PUT /api/bookings/:bookingId/admin-status — full admin status override
// Updates ip_bookings + ip_technician_collection + ip_booking_requests in sync
// Secured by X-Admin-Secret header (value = ADMIN_WEBHOOK_SECRET in .env)
router.put('/:bookingId/admin-status',  adminSecret, bookingController.updateAdminStatus);

// POST /api/bookings/admin — create booking from admin portal + auto-dispatch same-day
// Secured by HMAC-SHA256 shared secret (adminAuth middleware), not JWT
// Signing payload: "|timestamp"  (no bookingId in URL — bookingId param is empty string)
router.post('/admin', adminAuth, bookingController.createAdminBooking);

// POST /api/bookings/:bookingId/dispatch — trigger dispatch from admin portal
// Secured by HMAC-SHA256 shared secret (adminAuth middleware), not JWT
router.post('/:bookingId/dispatch', adminAuth, bookingController.dispatchBooking);

module.exports = router;
