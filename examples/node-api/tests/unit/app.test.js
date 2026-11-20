import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../../src/app.js';
import { memoryDb } from '../../src/memory.js';

let server, base;
before(async () => {
  server = createApp(memoryDb()).listen(0);
  await new Promise((r) => server.once('listening', r));
  base = `http://localhost:${server.address().port}`;
});
after(() => server.close());

test('/health répond 200 quand la base répond', async () => {
  const res = await fetch(`${base}/health`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { status: 'ok', db: 'up', version: 'dev', env: 'local' });
});

test('/health répond 503 quand la base ne répond pas', async () => {
  const down = createApp({ ping: () => Promise.reject(new Error('down')) }).listen(0);
  await new Promise((r) => down.once('listening', r));
  const res = await fetch(`http://localhost:${down.address().port}/health`);
  down.close();
  assert.equal(res.status, 503);
  assert.equal((await res.json()).db, 'down');
});

test('crée puis liste une tâche', async () => {
  const created = await fetch(`${base}/tasks`, { method: 'POST', body: JSON.stringify({ title: 'Écrire la CI' }) });
  assert.equal(created.status, 201);
  const list = await (await fetch(`${base}/tasks`)).json();
  assert.equal(list.at(-1).title, 'Écrire la CI');
});

test('refuse une tâche sans titre', async () => {
  const res = await fetch(`${base}/tasks`, { method: 'POST', body: '{}' });
  assert.equal(res.status, 400);
});

test('route inconnue : 404', async () => {
  assert.equal((await fetch(`${base}/nope`)).status, 404);
});
