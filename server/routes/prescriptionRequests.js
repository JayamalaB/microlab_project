const express = require('express');
const router  = express.Router();
const ctrl    = require('../controllers/prescriptionRequestController');
const auth    = require('../middleware/auth');

// POST /api/prescription-requests — submit prescription request
router.post('/', auth, ctrl.submit);

// GET /api/prescription-requests/mine — patient's own requests
router.get('/mine', auth, ctrl.getMine);

module.exports = router;
