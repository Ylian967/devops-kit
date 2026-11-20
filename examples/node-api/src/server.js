import { createApp } from './app.js';
import { memoryDb } from './memory.js';
import { postgresDb } from './postgres.js';

const { DATABASE_URL, PORT = 3000, APP_VERSION = 'dev', APP_ENV = 'local' } = process.env;
const db = DATABASE_URL ? await postgresDb(DATABASE_URL) : memoryDb();
createApp(db, { version: APP_VERSION, env: APP_ENV }).listen(PORT);
