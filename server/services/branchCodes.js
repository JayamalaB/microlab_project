'use strict';
// ip_branches.branch_code ↔ ip_branches.branch_id.
//
// branch_code is how a branch is identified with the external ASMX system
// (TechnicianLoginCheck's branch_id / default_branch_id, e.g. "07"; the
// visit_completed payload's branch_id). branch_id stays the internal key that
// every other table references (ip_bookings, ip_technicians, slots …), so an
// external code is turned into its branch_id once, at the boundary, and all
// internal matching keeps using branch_id.
//
// Matching: codes are trimmed; purely numeric codes also match regardless of
// leading zeros ("7" = "07" = "007"). Other codes ("CBE01") must match exactly.
// Only branches that are not soft-deleted are considered.
const db = require('../config/db');

function branchCodeKey(code) {
  if (code === null || code === undefined) return null;
  const s = String(code).trim();
  if (s === '') return null;
  return /^\d+$/.test(s) ? String(parseInt(s, 10)) : s;
}

// Map of matching key → branch_id for every non-deleted branch that has a code.
// method: 'execute' or 'query' — whichever the caller already uses on db.
async function loadBranchCodeMap(method = 'execute') {
  const [rows] = await db[method](
    `SELECT branch_id, branch_code FROM ip_branches
     WHERE deleted_at IS NULL AND branch_code IS NOT NULL AND branch_code <> ''`
  );
  const map = new Map();
  for (const r of rows) {
    const key = branchCodeKey(r.branch_code);
    if (key != null && !map.has(key)) map.set(key, Number(r.branch_id));
  }
  return map;
}

// "07" → branch_id of the branch whose branch_code is "07", or null.
async function resolveBranchIdByCode(code, method = 'execute') {
  const key = branchCodeKey(code);
  if (key == null) return null;
  const map = await loadBranchCodeMap(method);
  return map.get(key) ?? null;
}

// branch_id → that branch's branch_code (trimmed), or null when it has none.
async function getBranchCode(branchId, method = 'execute') {
  if (branchId === null || branchId === undefined || branchId === '') return null;
  const [[row]] = await db[method](
    'SELECT branch_code FROM ip_branches WHERE branch_id = ? LIMIT 1',
    [branchId]
  );
  const code = row?.branch_code;
  return code === null || code === undefined || String(code).trim() === '' ? null : String(code).trim();
}

module.exports = { branchCodeKey, loadBranchCodeMap, resolveBranchIdByCode, getBranchCode };
