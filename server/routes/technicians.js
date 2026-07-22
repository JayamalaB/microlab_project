const express = require('express');
const router = express.Router();
const technicianController = require('../controllers/technicianController');
const auth = require('../middleware/auth');

// Static POST/GET routes must be registered BEFORE /:technicianId to avoid path collision
router.post('/add-customer',            auth, technicianController.addCustomerBooking);
router.post('/collect-payment',         auth, technicianController.collectPayment);
router.post('/add-visit-member',        auth, technicianController.addVisitMember);
router.get('/patient-lookup',           auth, technicianController.lookupPatient);
router.get('/booking-family',           auth, technicianController.getBookingFamily);

// Booking OTP (sample-collection handoff)
router.post('/booking-otp/generate',    auth, technicianController.generateBookingOtp);
router.post('/booking-otp/verify',      auth, technicianController.verifyBookingOtp);
router.post('/booking-otp/resend',      auth, technicianController.resendBookingOtp);

// GET /api/technicians/:technicianId/profile — profile + today's stats
router.get('/:technicianId/profile', technicianController.getProfile);

// GET /api/technicians/:technicianId/history — completed + cancelled bookings
router.get('/:technicianId/history', technicianController.getHistory);

// GET /api/technicians/:technicianId/active-bookings — pending jobs (assigned/en_route/arrived)
router.get('/:technicianId/active-bookings', technicianController.getActiveBookings);

// POST /api/technicians/:technicianId/logout — close session + clear token
router.post('/:technicianId/logout', technicianController.logoutTechnician);

// GET /api/technicians/:technicianId/slots — master slots + technician config
router.get('/:technicianId/slots', technicianController.getSlots);

// PUT /api/technicians/:technicianId/slots — save availability slots
router.put('/:technicianId/slots', technicianController.saveSlots);

// GET /api/technicians/stats  — total / online / offline counts
router.get('/stats', technicianController.getStats);

// GET /api/technicians/live   — online technicians with GPS coordinates
router.get('/live', technicianController.getLive);

// GET /api/technicians/all    — all technicians with current status (admin)
router.get('/all', technicianController.getAll);

module.exports = router;
