import { test } from 'node:test';
import assert from 'node:assert/strict';
import { postgresDb } from '../../src/postgres.js';

// Ignoré sans DATABASE_URL (poste de dev sans base) ; la CI le fournit.
const url = process.env.DATABASE_URL;

test('PostgreSQL : insère et relit une tâche', { skip: !url && 'DATABASE_URL absent' }, async () => {
  const db = await postgresDb(url);
  await db.ping();
  const task = await db.addTask('tâche d’intégration');
  const rows = await db.listTasks();
  assert.ok(rows.some((r) => r.id === task.id));
  await db.close();
});
