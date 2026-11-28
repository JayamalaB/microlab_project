const express = require('express');
const router = express.Router();
const technicianController = require('../controllers/technicianController');
const auth = require('../middleware/auth');
const rolloutAuth = require('../middleware/rolloutAuth');
const { requireTechnician, requireSameTechnician } = require('../middleware/access');
const multer = require('multer');
const path   = require('path');
const fs     = require('fs');

// Technician profile photo: images only (served publicly from /uploads),
// named technician_<id>_… so login keeps it over the registry photo.
const UPLOAD_DIR = path.join(__dirname, '..', 'uploads');
if (!fs.existsSync(UPLOAD_DIR)) fs.mkdirSync(UPLOAD_DIR, { recursive: true });
const PHOTO_TYPES = new Set(['.jpg', '.jpeg', '.png', '.webp', '.heic']);
const photoUpload = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, UPLOAD_DIR),
    filename: (req, file, cb) => {
      const ext = (path.extname(file.originalname) || '.jpg').toLowerCase();
      cb(null, `technician_${Number(req.user.id)}_${Date.now()}_${Math.random().toString(36).slice(2, 8)}${ext}`);
    },
  }),
  limits: { fileSize: 5 * 1024 * 1024 }, // 5 MB
  fileFilter: (_req, file, cb) => {
    const ext = path.extname(file.originalname).toLowerCase();
    if (ext === '' || PHOTO_TYPES.has(ext)) return cb(null, true);
    cb(new Error('Only photos (JPG, PNG, WEBP, HEIC) can be uploaded'));
  },
});
function receivePhoto(req, res, next) {
  photoUpload.single('photo')(req, res, (err) =>
    err ? res.status(422).json({ success: false, message: err.message || 'Upload failed' }) : next());
}

// Static POST/GET routes must be registered BEFORE /:technicianId to avoid path collision
router.post('/add-customer',            auth, requireTechnician, technicianController.addCustomerBooking);
router.post('/collect-payment',         auth, requireTechnician, technicianController.collectPayment);
router.post('/create-qr',              auth, requireTechnician, technicianController.createQrPayment);
router.get('/qr-status/:qrId',         auth, requireTechnician, technicianController.getQrStatus);
router.put('/bookings/:bookingId/additional-charge', auth, requireTechnician, technicianController.setAdditionalCharge);
router.get('/charge-packages',          auth, requireTechnician, technicianController.getChargePackages);
router.get('/bookings/:bookingId/additional-charges',            auth, requireTechnician, technicianController.getAdditionalCharges);
router.post('/bookings/:bookingId/additional-charges',           auth, requireTechnician, technicianController.addAdditionalCharges);
router.delete('/bookings/:bookingId/additional-charges/:chargeId', auth, requireTechnician, technicianController.removeAdditionalCharge);
router.post('/add-visit-member',        auth, requireTechnician, technicianController.addVisitMember);
router.post('/remove-visit-member',     auth, requireTechnician, technicianController.removeVisitMember);
router.get('/patient-lookup',           auth, requireTechnician, technicianController.lookupPatient);
router.get('/booking-family',           auth, requireTechnician, technicianController.getBookingFamily);
router.post('/cancel-booking',          auth, requireTechnician, technicianController.cancelAssignedBooking);
router.put('/profile',                  auth, requireTechnician, technicianController.updateProfile);
router.post('/profile/photo',           auth, requireTechnician, receivePhoto, technicianController.uploadProfilePhoto);
router.delete('/profile/photo',         auth, requireTechnician, technicianController.removeProfilePhoto);
router.get('/reschedule-slots',         auth, requireTechnician, technicianController.getRescheduleSlots);
router.post('/reschedule-booking',      auth, requireTechnician, technicianController.rescheduleAssignedBooking);

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
