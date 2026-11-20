// Dépôt en mémoire : sert aux tests unitaires et au lancement sans base.
export function memoryDb() {
  const tasks = [];
  return {
    ping: async () => {},
    listTasks: async () => tasks,
    addTask: async (title) => {
      const task = { id: tasks.length + 1, title };
      tasks.push(task);
      return task;
    },
  };
}
