'use strict';

class TableManager {
    constructor() {
        this.tables = {
            ip_products: {
                name:       'ip_products',
                key_fields: ['product_name', 'product_description', 'product_price', 'pre_instructions']
            },
            ip_branches: {
                name:       'ip_branches',
                key_fields: ['branch_name', 'branch_address', 'branch_city', 'branch_state',
                             'branch_pincode', 'branch_mobile', 'branch_email']
            }
        };
    }

    identifyRelevantTables(question) {
        const q = question.toLowerCase();
        const tables = new Set();

        if (q.match(/test|package|price|cost|fasting|instruction|preparation|blood|urine|thyroid|lipid|cbc|hba1c|vitamin|serology|molecular|cytogenetics|microbiology|biochemistry|report|tat|available|panel|checkup/)) {
            tables.add('ip_products');
        }
        if (q.match(/branch|location|address|city|centre|center|nearest|where|coimbatore|trichy|phone|mobile|email|contact|clinic|lab near/)) {
            tables.add('ip_branches');
        }
        if (tables.size === 0) {
            tables.add('ip_products');
        }
        return { tables: Array.from(tables) };
    }

    getTableInfo() {
        return this.tables;
    }
}

module.exports = new TableManager();
