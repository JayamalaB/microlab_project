const express = require('express');
const router = express.Router();
const technicianController = require('../controllers/technicianController');

// GET /api/technicians/stats  — total / online / offline counts
router.get('/stats', technicianController.getStats);

// GET /api/technicians/live   — online technicians with GPS coordinates
router.get('/live', technicianController.getLive);

// GET /api/technicians/all    — all technicians with current status (admin)
router.get('/all', technicianController.getAll);

module.exports = router;
