const express = require('express');
const router = express.Router();
const testController = require('../controllers/testController');

// GET /api/tests — catalog (full list, or one page with ?limit=&offset=)
router.get('/', testController.getCatalog);

// GET /api/tests/categories — category names for the filter chips
// (must stay above /:id, or "categories" would be read as a product id)
router.get('/categories', testController.getCategories);

// GET /api/tests/:id — single test
router.get('/:id', testController.getTest);

module.exports = router;
