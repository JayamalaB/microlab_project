const express = require('express');
const router = express.Router();
const bookingController = require('../controllers/bookingController');
const auth = require('../middleware/auth');

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

// POST /api/bookings/:bookingId/pay — pay a pending booking via Razorpay
router.post('/:bookingId/pay', auth, bookingController.payBooking);

// PUT /api/bookings/:bookingId/items — replace tests/packages on an existing booking
router.put('/:bookingId/items', auth, bookingController.updateBookingItems);

// PUT /api/bookings/:bookingId/lab-status — update lab pipeline stage
router.put('/:bookingId/lab-status', bookingController.updateLabStatus);

module.exports = router;
