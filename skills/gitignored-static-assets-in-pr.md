# Gitignored Static Assets in PR Workflows

## Context
When a project stores static files (e.g., `public/`) in a gitignored directory but deploys them separately from the main Cloud Build/CI pipeline, there are specific patterns needed to handle PRs correctly.

## The Problem
- `public/` directory is gitignored (e.g., in `.gitignore`)
- Static files are deployed via a separate mechanism (e.g., Render.com, direct GCS sync, or a separate Cloud Build step)
- The `pr-dev-preview.yml` workflow only triggers on specific path patterns (e.g., `backend/**`, `package.json`) — NOT on `public/**`
- Result: even with a valid PR, the preview URL won't reflect `public/` changes automatically

## The Pattern

### Step 1 — Discover the gitignore
```bash
git check-ignore public/    # returns "public/" if gitignored
cat .gitignore               # confirm the entry
cat .dockerignore            # also check — files may be excluded from Docker builds too
```

### Step 2 — Force-add to PR
```bash
git add -f public/consulting.html    # -f bypasses gitignore warning
git commit
git push
```

### Step 3 — Note the sync gap in the PR
Always add an "Architecture Note" section in the PR description explaining that:
1. The file is gitignored and deployed separately
2. Preview URL won't auto-update via CI
3. The file must be synced to the static asset store manually (or the CI trigger must be updated)

### Step 4 (optional) — Fix the CI trigger
If you want future `public/` changes to get automatic preview deployments, add to `pr-dev-preview.yml`:

```yaml
on:
  pull_request:
    paths:
      - 'public/**'          # ADD THIS
      - 'backend/**'
      - ...existing paths...
```

## Example: ai_universe consulting page
- Repo: `jleechanorg/ai_universe`
- Gitignored: `public/` (via `.gitignore`)
- Static deployment: Render.com (via `render.yaml`) + Cloud Run serves from built image
- Preview CI trigger: `pr-dev-preview.yml` — does NOT watch `public/**`
- Workaround: force-add with `git add -f`, document the sync gap in PR

## Key Commands Reference
```bash
# Check if a path is gitignored
git check-ignore public/

# Confirm what's in .gitignore
grep "public" .gitignore

# Force-add gitignored file to staging
git add -f path/to/file

# Check Dockerignore (files not included in Docker builds)
cat .dockerignore | grep public

# Check which CI triggers fire for a path
gh run list --workflow=pr-dev-preview.yml --repo owner/repo
```

## When to Use This Pattern
- Static HTML landing pages in a primarily app/backend repo
- Assets like images, fonts, or JSON data deployed to a CDN separately
- Documentation sites built and deployed separately from app code
- Any file pattern that is gitignored but still needs to be in the repo for deployment
