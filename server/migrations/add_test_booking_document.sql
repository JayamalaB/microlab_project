-- Run once on the production database.
-- Adds document_url (optional image/PDF attachment) to test_bookings, and makes
-- package nullable since the chatbot's Book Test form no longer asks for one.

ALTER TABLE test_bookings
  ADD COLUMN IF NOT EXISTS document_url VARCHAR(500) DEFAULT NULL;

ALTER TABLE test_bookings
  MODIFY COLUMN package VARCHAR(255) DEFAULT NULL;
