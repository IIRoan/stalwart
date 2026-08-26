# Railway configuration

This repository is a named partial of the Rocal project (`export const partial = "stalwart"`). It owns **stalwart-mail**, **Monitoring**, **Postgres-stalwart**, their volumes, and the **stalwart-blobs** bucket. Solace web/API services stay in the other repo.

```txt
.railway/railway.ts
```

Preview:

```bash
railway config plan
```

Apply after reviewing the plan:

```bash
railway config apply
```

`plan` is read-only. `apply` asks before changing Railway. Destructive applies in agent sessions also need `--confirm-destructive`.
