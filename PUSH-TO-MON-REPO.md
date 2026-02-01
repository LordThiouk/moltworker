# Pousser le code vers ton repo personnel

Actuellement `origin` pointe vers `https://github.com/cloudflare/moltworker.git`.

## Option 1 : Remplacer origin par ton repo (recommandé)

1. **Crée un nouveau repo sur GitHub** (vide, sans README) : <https://github.com/new>  
   Exemple : `https://github.com/TON_USERNAME/moltworker`

2. **Change le remote origin** (remplace `TON_USERNAME` par ton pseudo GitHub) :

   ```bash
   git remote set-url origin https://github.com/TON_USERNAME/moltworker.git
   ```

3. **Vérifie** :

   ```bash
   git remote -v
   ```

4. **Commit et push** :

   ```bash
   git add .
   git status
   git commit -m "Local dev Windows, deploy workflow, .dev.vars"
   git push -u origin main
   ```

Tu gardes tout l’historique et les futurs push iront vers ton repo.

---

## Option 2 : Garder cloudflare/moltworker et ajouter ton repo

Si tu veux garder `origin` = Cloudflare (pour comparer ou faire des PR plus tard) :

1. **Crée ton repo** sur GitHub (vide).

2. **Ajoute ton repo comme remote** (remplace `TON_USERNAME`) :

   ```bash
   git remote add monrepo https://github.com/TON_USERNAME/moltworker.git
   ```

3. **Push vers ton repo** :

   ```bash
   git add .
   git commit -m "Local dev Windows, deploy workflow, .dev.vars"
   git push -u monrepo main
   ```

Ensuite tu pourras faire `git push monrepo main` pour pousser vers ton repo, et `git fetch origin` pour récupérer les mises à jour du repo Cloudflare.
