const express = require('express');
const router = express.Router();
const testController = require('../controllers/testController');

// GET /api/tests — full catalog
router.get('/', testController.getCatalog);

// GET /api/tests/categories — distinct categories
router.get('/categories', testController.getCategories);

// GET /api/tests/:id — single test
router.get('/:id', testController.getTest);

module.exports = router;
