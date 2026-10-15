// A fake transactional connection, for the many controllers that do
// `const conn = await db.getConnection(); await conn.beginTransaction(); ...`
// instead of calling db.execute/db.query directly (booking creation, family
// bookings, technician logout, updateBookingItems, and more all follow this
// pattern). Wire it up with: db.getConnection.mockResolvedValue(conn).
function createMockConnection() {
  const conn = {
    beginTransaction: jest.fn().mockResolvedValue(undefined),
    commit:           jest.fn().mockResolvedValue(undefined),
    rollback:         jest.fn().mockResolvedValue(undefined),
    release:          jest.fn(),
    execute: jest.fn().mockResolvedValue([[], {}]),
    query:   jest.fn().mockResolvedValue([[], {}]),
  };
  return conn;
}

module.exports = { createMockConnection };
