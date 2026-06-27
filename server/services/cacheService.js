const redis = require('redis');
require('dotenv').config();

class CacheService {
    constructor() {
        this.client = null;
        this.isConnected = false;
        this.defaultTTL = 300;

        this.ttlConfig = {
            intent:       3600,
            query_result: 300,
            llm_answer:   600,
            schema:       86400,
            conversation: 1800
        };
    }

    async connect() {
        try {
            this.client = redis.createClient({
                socket: {
                    host: process.env.REDIS_HOST || '127.0.0.1',
                    port: parseInt(process.env.REDIS_PORT) || 6379,
                    reconnectStrategy: (retries) => {
                        if (retries > 5) {
                            console.warn('⚠️ Redis: max reconnect attempts reached, disabling cache');
                            return false;
                        }
                        return Math.min(retries * 200, 2000);
                    }
                },
                password: process.env.REDIS_PASSWORD || undefined
            });

            this.client.on('error', (err) => {
                if (this.isConnected) {
                    console.warn('⚠️ Redis error (cache disabled):', err.message);
                }
                this.isConnected = false;
            });

            this.client.on('connect', () => {
                this.isConnected = true;
                console.log('✅ Redis connected — caching enabled');
            });

            this.client.on('reconnecting', () => {
                console.log('🔄 Redis reconnecting...');
            });

            await this.client.connect();
        } catch (err) {
            console.warn('⚠️ Redis unavailable — running without cache:', err.message);
            this.isConnected = false;
        }
    }

    async get(key) {
        if (!this.isConnected || !this.client) return null;
        try {
            const raw = await this.client.get(key);
            if (!raw) return null;
            return JSON.parse(raw);
        } catch (err) {
            console.warn('⚠️ Cache get error:', err.message);
            return null;
        }
    }

    async set(key, value, ttl = this.defaultTTL) {
        if (!this.isConnected || !this.client) return false;
        try {
            await this.client.setEx(key, ttl, JSON.stringify(value));
            return true;
        } catch (err) {
            console.warn('⚠️ Cache set error:', err.message);
            return false;
        }
    }

    async del(key) {
        if (!this.isConnected || !this.client) return false;
        try {
            await this.client.del(key);
            return true;
        } catch (err) {
            console.warn('⚠️ Cache del error:', err.message);
            return false;
        }
    }

    async flush(pattern = '*') {
        if (!this.isConnected || !this.client) return false;
        try {
            const keys = await this.client.keys(pattern);
            if (keys.length > 0) {
                await this.client.del(keys);
                console.log(`🧹 Cache FLUSH: ${keys.length} keys matching "${pattern}"`);
            }
            return true;
        } catch (err) {
            console.warn('⚠️ Cache flush error:', err.message);
            return false;
        }
    }

    _hash(input) {
        const { createHash } = require('crypto');
        return createHash('sha256').update(input.toLowerCase().trim()).digest('hex');
    }

    async getIntent(question) {
        return this.get(`intent:${this._hash(question)}`);
    }

    async setIntent(question, intentData) {
        return this.set(`intent:${this._hash(question)}`, intentData, this.ttlConfig.intent);
    }

    async getQueryResult(sql) {
        return this.get(`query_result:${this._hash(sql)}`);
    }

    async setQueryResult(sql, rows) {
        return this.set(`query_result:${this._hash(sql)}`, rows, this.ttlConfig.query_result);
    }

    async getLLMAnswer(question) {
        return this.get(`llm_answer:${this._hash(question)}`);
    }

    async setLLMAnswer(question, answer) {
        return this.set(`llm_answer:${this._hash(question)}`, answer, this.ttlConfig.llm_answer);
    }

    async getSchema() {
        return this.get('schema:all_tables');
    }

    async setSchema(schemas) {
        return this.set('schema:all_tables', schemas, this.ttlConfig.schema);
    }

    async ttl(key) {
        if (!this.isConnected || !this.client) return -2;
        try {
            return await this.client.ttl(key);
        } catch {
            return -2;
        }
    }

    async disconnect() {
        if (this.client && this.isConnected) {
            await this.client.quit();
            console.log('🔌 Redis disconnected');
        }
    }
}

const cacheService = new CacheService();
module.exports = cacheService;
