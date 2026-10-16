// Tests server/middleware/safeErrorResponse.js — error replies reach the
// apps without internal details, and 5xx replies get a plain message.
const express = require('express');
const request = require('supertest');
const safeErrorResponse = require('../../middleware/safeErrorResponse');
const { FRIENDLY_SERVER_ERROR } = safeErrorResponse;

function appReplying(status, body) {
  const app = express();
  app.use(safeErrorResponse);
  app.get('/x', (req, res) => res.status(status).json(body));
  return app;
}

beforeEach(() => jest.spyOn(console, 'error').mockImplementation(() => {}));
afterEach(() => console.error.mockRestore());

describe('safeErrorResponse', () => {
  test('5xx: detail/sqlState/debug removed and the message made friendly', async () => {
    const res = await request(appReplying(500, {
      success: false, message: 'Server error', detail: "Unknown column 'x' in 'field list'",
      sqlState: '42S22', debug: 'sql=SELECT ...', code: 'ER_BAD_FIELD_ERROR',
    })).get('/x');

    expect(res.status).toBe(500);
    expect(res.body).toEqual({ success: false, message: FRIENDLY_SERVER_ERROR });
    expect(console.error).toHaveBeenCalled(); // original kept in the log
  });

  test('5xx with a raw exception as the message is replaced too', async () => {
    const res = await request(appReplying(500, {
      success: false, message: "Cannot read properties of undefined (reading 'id')",
    })).get('/x');
    expect(res.body.message).toBe(FRIENDLY_SERVER_ERROR);
  });

  test('5xx "error" field is replaced as well', async () => {
    const res = await request(appReplying(500, { success: false, error: 'ECONNREFUSED 127.0.0.1:3306' })).get('/x');
    expect(res.body.error).toBe(FRIENDLY_SERVER_ERROR);
  });

  test('5xx with an app error code keeps its own message', async () => {
    const body = { success: false, code: 'RATE_NOT_FOUND', message: "Home Collection pricing isn't available right now." };
    const res = await request(appReplying(503, body)).get('/x');
    expect(res.body).toEqual(body);
  });

  test('4xx messages are left alone, but internal fields still removed', async () => {
    const res = await request(appReplying(422, {
      success: false, message: 'Please choose a branch.', detail: 'branch_id null',
    })).get('/x');
    expect(res.body).toEqual({ success: false, message: 'Please choose a branch.' });
  });

  test('success replies are untouched', async () => {
    const body = { success: true, data: [1, 2], detail: 'kept' };
    const res = await request(appReplying(200, body)).get('/x');
    expect(res.body).toEqual(body);
  });
});
