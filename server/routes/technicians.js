const express = require('express');
const router = express.Router();
const technicianController = require('../controllers/technicianController');
const auth = require('../middleware/auth');

// POST /api/technicians/add-customer — technician adds a walk-in patient on-site
// Must be registered BEFORE /:technicianId routes to avoid path collision
router.post('/add-customer', auth, technicianController.addCustomerBooking);

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
