const express = require('express');
const router  = express.Router();
const branchController = require('../controllers/branchController');

// GET /api/branches/lookup?pincode=600042&place=Anna+Nagar
router.get('/lookup', branchController.lookupBranch);

// GET /api/branches/slots?branchId=1&date=2026-06-21
router.get('/slots', branchController.getAvailableSlots);

module.exports = router;
