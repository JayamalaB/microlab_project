const OpenAI = require('openai');
require('dotenv').config();

class LLMService {
    constructor() {
        this.openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
        this.conversationMemory = new Map();
    }

    getConversationContext(sessionId) {
        if (!this.conversationMemory.has(sessionId)) {
            this.conversationMemory.set(sessionId, []);
        }
        return this.conversationMemory.get(sessionId).slice(-5);
    }

    saveToMemory(sessionId, userMessage, botResponse) {
        if (!this.conversationMemory.has(sessionId)) {
            this.conversationMemory.set(sessionId, []);
        }
        this.conversationMemory.get(sessionId).push(
            { role: 'user', content: userMessage },
            { role: 'assistant', content: botResponse }
        );
    }

    isGeneralQuestion(question) {
        const generalPatterns = [
            /^hi|^hello|^hey|^greetings/i,
            /how are you/i,
            /what can you do|how can you help|your capabilities/i,
            /thank|thanks/i,
            /good morning|good afternoon|good evening/i,
            /who are you|what are you/i,
            /bye|goodbye|see you/i
        ];
        return generalPatterns.some(p => p.test(question));
    }

    async handleGeneralQuestion(question) {
        const q = question.toLowerCase();

        if (q.match(/^hi|^hello|^hey|^greetings/)) {
            return "👋 Hello! I'm your MicroLab assistant. Ask me about our tests, bookings, branches, or report timings.";
        }
        if (q.includes('how are you')) {
            return "I'm doing great, thanks for asking! Ready to help with your MicroLab queries.";
        }
        if (q.includes('what can you do') || q.includes('how can you help') || q.includes('capabilities')) {
            return `📋 I can help you with:

❓ Help & FAQ — hours, payment, home collection, cancellation
🧪 Tests & Prices — available tests, pricing, fasting instructions
🏥 About Lab — MicroLab services, doctors, capabilities
🩺 Book Test — schedule a diagnostic test

Try asking:
• "What tests are available?"
• "What is the price of a Lipid Profile?"
• "Do I need to fast for CBC?"
• "Where is your Coimbatore branch?"
• "What are your working hours?"`;
        }
        if (q.includes('thank')) return "You're welcome! 😊 Anything else I can help you with?";
        if (q.includes('bye') || q.includes('goodbye')) return "Goodbye! Feel free to reach out again. 👋";
        if (q.includes('who are you')) return "I'm MicroLab's AI assistant. I can help with test bookings, branch info, reports, and general lab queries.";

        return null;
    }

    async parseIntent(question, context = '') {
        if (this.isGeneralQuestion(question)) {
            const response = await this.handleGeneralQuestion(question);
            if (response) {
                return {
                    intent: 'general',
                    entities: {},
                    general_response: response,
                    clarification_needed: false
                };
            }
        }

        try {
            const prompt = `You are a database query assistant for MicroLab, a diagnostic laboratory. Be precise and concise.

Database Schema (ONLY these tables exist — never reference any other table):
- ip_products: product_name, product_description, product_price, pre_instructions
  (ALL diagnostic tests AND health packages. "packages", "tests", "health checkup", "panel", "available tests", "what packages", "list tests" ALL refer to this table)
- ip_branches: branch_name, branch_address, branch_city, branch_state, branch_pincode, branch_mobile, branch_email
  (lab branch locations and contact info)
- ip_sample_tracking: sample_id, sample_barcode, booking_id, sample_type, sample_status, collected_at, results_ready_at, reported_at, notes
  (patient's own sample/report status — ONLY use when patient asks about THEIR OWN sample/report/result status)
- ip_patients: patient_name, patient_surname, patient_gender, patient_dob, patient_age, patient_blood_group, patient_relation, patient_email, patient_mobile, patient_address, patient_city, health_conditions
  (the logged-in patient's own profile PLUS family members registered under the same account — ONLY use when patient asks about THEIR OWN profile, a family member/relative, or "who is on my account")
- ip_clients: client_name, client_mobile_no, subscription_tier, client_account_status
  (the logged-in patient's account/subscription info — ONLY use when patient asks about THEIR OWN subscription plan or account status)
- ip_bookings + ip_booking_items + ip_booking_documents + ip_available_slots
  (the logged-in patient's OWN bookings — status, payment, appointment slot date/time, the tests/items
  booked, and how many documents are attached. ONLY use when patient asks about THEIR OWN booking(s),
  e.g. "my booking", "booking details", "booking status", "track my booking", "booking history")
- ip_technicians (joined via ip_bookings.technician_id)
  (the technician assigned to one of the patient's OWN bookings — name, specialization, certifications,
  availability. ONLY use when patient asks "technician info", "who is my technician", "which technician",
  "assigned technician". Defaults to the LATEST booking unless the patient names a specific booking
  reference/id.)

Intent rules:
- "show all tests", "list tests", "available tests", "what tests do you have" → test_query, keyword: null (list all)
- "price of CBC", "Lipid Profile test" → test_query, product_name: extracted name
- "thyroid tests", "blood tests" → test_query, keyword: category word only
- "where is branch", "Coimbatore location" → branch_query
- "my sample status", "where is my report", "track my test", "my result", "has my sample been collected" → sample_status_query
- "who are my family members", "list patients on my account", "my profile", "my blood group", "my mother's details" → patient_profile_query
- "my subscription", "my plan", "my account status", "is my account active" → client_account_query
- "my booking", "booking details", "booking status", "track my booking", "latest booking" → booking_query, booking_history: false
- "booking history", "all my bookings", "past bookings", "show my bookings" → booking_query, booking_history: true
- "technician info", "who is my technician", "which technician", "assigned technician" → technician_info_query
- NEVER set keyword to "available tests", "all tests", "show all" — those mean list everything

User Question: "${question}"

Respond with ONLY a JSON object (no extra text):
{
    "intent": "test_query|branch_query|sample_status_query|patient_profile_query|client_account_query|booking_query|technician_info_query|general",
    "entities": {
        "product_name": "specific test or package name, or null",
        "keyword": "category/type to search (e.g. thyroid, blood, vitamin), or null",
        "branch_name": "specific branch name, or null",
        "city": "city name (e.g. Coimbatore, Trichy), or null",
        "price_query": true/false,
        "fasting_query": true/false,
        "booking_id": "booking ID or booking reference if patient mentions one, or null",
        "relation": "family relation mentioned, e.g. mother, father, spouse, child, self, or null",
        "person_name": "specific family member's name mentioned, or null",
        "booking_history": true/false
    },
    "is_general": true/false
}`;

            const response = await this.openai.chat.completions.create({
                model: 'gpt-3.5-turbo',
                messages: [{ role: 'user', content: prompt }],
                temperature: 0.2,
                max_tokens: 300
            });

            const result = JSON.parse(response.choices[0].message.content);
            console.log('🧠 LLM Intent:', result);

            return result;

        } catch (error) {
            console.error('LLM Intent parsing error:', error);
            return { intent: 'general_query', entities: {}, is_general: false };
        }
    }

    async formatResponse(question, intent, entities, data, error = null) {
        if (error) {
            return `⚠️ Sorry, I encountered an error: ${error.substring(0, 100)}. Please try again.`;
        }

        if (!data || data.length === 0) {
            return `🔍 I couldn't find any information matching "${question}". Try asking about available tests, branch locations, or booking help.`;
        }

        try {
            const prompt = `Convert this data into a clear, complete response.

User Question: "${question}"
Intent: ${intent}

Data: ${JSON.stringify(data, null, 2)}

Rules:
1. Cover ALL items in the data — do not truncate or summarise away results
2. Use emojis sparingly (max 2)
3. Focus ONLY on what was asked
4. Be direct — no fluff or extra explanations
5. Include prices/dates only if relevant to the question

Response:`;

            const response = await this.openai.chat.completions.create({
                model: 'gpt-3.5-turbo',
                messages: [{ role: 'user', content: prompt }],
                temperature: 0.5,
                max_tokens: 500
            });

            return response.choices[0].message.content;

        } catch (error) {
            console.error('LLM Formatting error:', error);
            return this.fallbackResponse(data);
        }
    }

    fallbackResponse(data) {
        if (!data || data.length === 0) return 'No results found.';
        if (data.length === 1) {
            const item = data[0];
            if (item.product_name && item.product_price) return `${item.product_name}: ₹${item.product_price}`;
            if (item.product_name) return item.product_name;
            if (item.branch_name)  return `${item.branch_name} — ${item.branch_city || ''} | ${item.branch_mobile || ''}`;
        }
        const names = data.map(d => d.product_name || d.branch_name).filter(Boolean);
        return names.length ? `Found: ${names.join(', ')}.` : `Found ${data.length} results.`;
    }
}

module.exports = new LLMService();
