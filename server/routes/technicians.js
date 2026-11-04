const express = require('express');
const router = express.Router();
const technicianController = require('../controllers/technicianController');
const auth = require('../middleware/auth');
const rolloutAuth = require('../middleware/rolloutAuth');
const { requireTechnician, requireSameTechnician } = require('../middleware/access');

// Static POST/GET routes must be registered BEFORE /:technicianId to avoid path collision
router.post('/add-customer',            auth, requireTechnician, technicianController.addCustomerBooking);
router.post('/collect-payment',         auth, requireTechnician, technicianController.collectPayment);
router.post('/create-qr',              auth, requireTechnician, technicianController.createQrPayment);
router.get('/qr-status/:qrId',         auth, requireTechnician, technicianController.getQrStatus);
router.put('/bookings/:bookingId/additional-charge', auth, requireTechnician, technicianController.setAdditionalCharge);
router.post('/add-visit-member',        auth, requireTechnician, technicianController.addVisitMember);
router.get('/patient-lookup',           auth, requireTechnician, technicianController.lookupPatient);
router.get('/booking-family',           auth, requireTechnician, technicianController.getBookingFamily);
router.post('/cancel-booking',          auth, requireTechnician, technicianController.cancelAssignedBooking);

// Booking OTP (sample-collection handoff)
router.post('/booking-otp/generate',    auth, requireTechnician, technicianController.generateBookingOtp);
router.post('/booking-otp/verify',      auth, requireTechnician, technicianController.verifyBookingOtp);
router.post('/booking-otp/resend',      auth, requireTechnician, technicianController.resendBookingOtp);

// GET /api/technicians/:technicianId/profile — profile + today's stats
router.get('/:technicianId/profile', rolloutAuth, requireSameTechnician, technicianController.getProfile);

// GET /api/technicians/:technicianId/history — completed + cancelled bookings
router.get('/:technicianId/history', rolloutAuth, requireSameTechnician, technicianController.getHistory);

// GET /api/technicians/:technicianId/active-bookings — pending jobs (assigned/en_route/arrived)
router.get('/:technicianId/active-bookings', rolloutAuth, requireSameTechnician, technicianController.getActiveBookings);

// POST /api/technicians/:technicianId/logout — close session + clear token
router.post('/:technicianId/logout', rolloutAuth, requireSameTechnician, technicianController.logoutTechnician);

// GET /api/technicians/:technicianId/slots — master slots + technician config
router.get('/:technicianId/slots', rolloutAuth, requireSameTechnician, technicianController.getSlots);

// PUT /api/technicians/:technicianId/slots — save availability slots
router.put('/:technicianId/slots', rolloutAuth, requireSameTechnician, technicianController.saveSlots);

// GET /api/technicians/stats  — total / online / offline counts
router.get('/stats', rolloutAuth, requireTechnician, technicianController.getStats);

// GET /api/technicians/live   — online technicians with GPS coordinates
router.get('/live', rolloutAuth, requireTechnician, technicianController.getLive);

// GET /api/technicians/all    — all technicians with current status (admin)
router.get('/all', rolloutAuth, requireTechnician, technicianController.getAll);

module.exports = router;
