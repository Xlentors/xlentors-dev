# xlentors-dev Cloud Run CI/CD

This directory contains the Cloud Run setup and deployment scripts.

## Environments

Production:
- Cloud Run service: `xlentors-dev`
- DNS: `xlentors.dev`
- Static IP resource: `xlentors-dev-ingress-ip`
- App image repo: `xlentors-dev-app`

Test:
- Cloud Run service: `test-xlentors-dev`
- DNS: `test-xlentors.dev`
- Static IP resource: `test-xlentors-dev-ingress-ip`
- App image repo: `test-xlentors-dev-app`

## First-time setup

Run this once before the next deployment:

```bash
bash cicd/setupsvc.sh create
```

This creates:
- Artifact Registry repo (`xlentors-dev-app`)
- Deployment service account (`xlentors-dev-deploy`)
- Global static ingress IP (`xlentors-dev-ingress-ip`)
- Cloud Build GitHub connection and repository mapping
- Production Cloud Build triggers (`xlentors-dev-cloudrun-deploy`, `xlentors-dev-cloudrun-deploy-manual`)

After `create` completes, point the `xlentors.dev` A record at the printed static IP in GoDaddy.

## Existing Cloud Build trigger

The existing trigger in GCP continues to work — it now uses the updated `cloudbuild.yaml`
at the repo root, which is identical to `cicd/cloudbuild-service.yaml`.

**Before the next push to main:** run `bash cicd/setupsvc.sh create` so the
`xlentors-dev-app` Artifact Registry repo and the `xlentors-dev-deploy` service account
exist. The trigger will fail without them.

Optionally, update the existing trigger in the Cloud Build console to point at
`cicd/cloudbuild-service.yaml` instead of `cloudbuild.yaml` — both files are identical.

## Commands

Create production artifacts:

```bash
bash cicd/setupsvc.sh create
```

Create test artifacts:

```bash
bash cicd/setupsvc.sh create --test
```

Deploy production:

```bash
bash cicd/setupsvc.sh deploy
```

Deploy test from a branch:

```bash
bash cicd/setupsvc.sh deploy --test --branch feature/my-branch
```

Show environment status:

```bash
bash cicd/setupsvc.sh status
bash cicd/setupsvc.sh status --test
```

Delete an environment:

```bash
bash cicd/setupsvc.sh delete
bash cicd/setupsvc.sh delete --test
```

Low-level diagnostics:

```bash
bash cicd/setupsvc.sh chkcert
bash cicd/setupsvc.sh chkbuild
bash cicd/setupsvc.sh tailbuild <build-id>
bash cicd/setupsvc.sh lsbuild
bash cicd/setupsvc.sh chkipa
bash cicd/setupsvc.sh chksvc
bash cicd/setupsvc.sh logsvc
```

## Notes

- Run `create` before `deploy`.
- `create` requires an active `gcloud` account with admin rights on `xlentors-dev`.
- Production triggers are created by `create`.
- Test triggers are created or updated on demand by `deploy --test --branch <name>`.
- `chkbuild` reads the last saved build id from `cicd/.state/`, unless you pass `--build-id <id>`.
- `tailbuild` takes a build id directly and does not accept `--test` or `--build-id`.
- `DNS_MANAGED_ZONE` is optional. Leave it empty if DNS stays in GoDaddy — the script will print the A record to set manually.
