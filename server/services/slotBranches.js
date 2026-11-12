'use strict';

// Which branches a technician's slot is offered at
// (migrations/add_technician_slot_branches.sql).
//
// A slot counts for branch X when the technician picked X for it
// (ip_technician_slot_branches), or — for a slot saved before branches could
// be picked, which has no rows there — when X is its own
// ip_technician_slots.branch_id. One slot, one capacity: offered at several
// branches, the first booking takes it for all of them.
//
// Every customer-facing slot query (slot list, branch selection, dispatch's
// slot fallback and "pick another time" list) filters with this.

// SQL condition on an ip_technician_slots alias: "this slot counts for the
// branch given as the parameter". Use slotAtBranchParams(branchId) for its
// two placeholders, in this position.
function slotAtBranchSql(alias = 'ts') {
  return `(EXISTS (SELECT 1 FROM ip_technician_slot_branches sb
                   WHERE sb.tech_slot_id = ${alias}.tech_slot_id AND sb.branch_id = ?)
           OR (${alias}.branch_id = ? AND NOT EXISTS (SELECT 1 FROM ip_technician_slot_branches sb0
                                                      WHERE sb0.tech_slot_id = ${alias}.tech_slot_id)))`;
}
const slotAtBranchParams = (branchId) => [branchId, branchId];

module.exports = { slotAtBranchSql, slotAtBranchParams };
