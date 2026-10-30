# Runbook: restore the orders namespace from backup

Velero backs up the `orders` namespace daily at 03:00 UTC and keeps backups for
14 days. The schedule is in `platform/addons/velero.yaml`.

Application state lives in SQS and Secrets Manager, not in the cluster, so a
restore mainly recovers Kubernetes objects. Because everything is also in Git,
**ArgoCD re-sync is the first option**. Use Velero when objects outside Git
were lost, or to test DR.

## Restore

```bash
velero backup get                                   # pick a Completed backup
velero restore create --from-backup <backup-name> \
  --include-namespaces orders --restore-volumes=true
velero restore describe <restore-name> --details    # check warnings and errors
```

To rehearse without touching live objects, restore into a scratch namespace:

```bash
velero restore create drill-$(date +%s) --from-backup <backup-name> \
  --namespace-mappings orders:orders-drill
```

## Verify

- `kubectl -n orders get rollout,deploy,svc,externalsecret`
- The API answers on `/readyz`, and the worker's queue age returns to baseline.
- Delete the drill namespace afterwards.

## Record

Log the drill, including the time to restore, in `docs/game-days.md`. A backup
that was never restored is not a backup.
