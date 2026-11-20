# node-api-exemple

Mini-API Node 22 (`node:http`, PostgreSQL optionnel) qui sert de **cobaye** aux blocs de devops-kit.
Elle ne contient volontairement **aucun** fichier DevOps : on applique les blocs dessus pour les tester.

```bash
npm ci
npm test                 # tests unitaires (dépôt en mémoire)
npm run test:coverage    # idem + couverture
DATABASE_URL=postgres://app:app@localhost:5432/app npm run test:int   # contre une vraie base
npm start                # http://localhost:3000/health
```
