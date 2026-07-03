const express = require('express');
const router = express.Router();
const branchController = require('../controllers/branchController');

router.get('/lookup', branchController.lookupBranch);
router.get('/', branchController.getBranches);

module.exports = router;
