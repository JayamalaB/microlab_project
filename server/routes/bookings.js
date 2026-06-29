const express = require('express');
const router = express.Router();
const bookingController = require('../controllers/bookingController');

// POST /api/bookings — create booking (returns bookingId)
router.post('/', bookingController.createBooking);

// GET /api/bookings/patient/:patientId — patient booking history
router.get('/patient/:patientId', bookingController.getPatientBookings);

// GET /api/bookings/:bookingId — single booking detail
router.get('/:bookingId', bookingController.getBooking);

// GET /api/bookings/:bookingId/tech-location — technician's last-known GPS
router.get('/:bookingId/tech-location', bookingController.getTechLocation);

// PUT /api/bookings/:bookingId/lab-status — update lab pipeline stage
// body: { status: 'sample_received' | 'test_in_progress' | 'report_ready', reportUrl? }
// Triggers socket push to patient
router.put('/:bookingId/lab-status', bookingController.updateLabStatus);

module.exports = router;
