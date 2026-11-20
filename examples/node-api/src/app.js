import http from 'node:http';

// Crée le serveur HTTP. `db` est injecté : un objet { ping(), listTasks(), addTask(title) }.
export function createApp(db, { version = 'dev', env = 'local' } = {}) {
  return http.createServer(async (req, res) => {
    const send = (status, body) => {
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    try {
      if (req.method === 'GET' && req.url === '/health') {
        const up = await db.ping().then(
          () => true,
          () => false,
        );
        return send(up ? 200 : 503, { status: up ? 'ok' : 'degraded', db: up ? 'up' : 'down', version, env });
      }
      if (req.method === 'GET' && req.url === '/tasks') return send(200, await db.listTasks());
      if (req.method === 'POST' && req.url === '/tasks') {
        let raw = '';
        for await (const chunk of req) raw += chunk;
        const title = JSON.parse(raw || '{}').title?.trim();
        if (!title) return send(400, { error: 'title requis' });
        return send(201, await db.addTask(title));
      }
      send(404, { error: 'introuvable' });
    } catch {
      send(500, { error: 'erreur interne' });
    }
  });
}
