import pg from 'pg';

// Dépôt PostgreSQL : crée la table au premier appel.
export async function postgresDb(connectionString) {
  const pool = new pg.Pool({ connectionString });
  await pool.query('CREATE TABLE IF NOT EXISTS tasks (id SERIAL PRIMARY KEY, title TEXT NOT NULL)');
  return {
    ping: () => pool.query('SELECT 1'),
    listTasks: async () => (await pool.query('SELECT id, title FROM tasks ORDER BY id')).rows,
    addTask: async (title) =>
      (await pool.query('INSERT INTO tasks (title) VALUES ($1) RETURNING id, title', [title])).rows[0],
    close: () => pool.end(),
  };
}
