# clear-canceled-sqs-tasks
a bash tool to help you reindex projects on SonarQube Server which were canceled or failed after reindexing

## Background

After a restart, upgrade, or redeploy, SonarQube queues one `ISSUE_SYNC` background task per project branch/PR to rebuild its Elasticsearch index. If any of those tasks end in a `CANCELED` or `FAILED` state, the global Issues page displays:

> *SonarQube Server is reindexing project data. This page is unavailable until this process is complete.*

## What the script does

1. Paginates through `api/ce/activity` to find every `CANCELED` or `FAILED` `ISSUE_SYNC` task.
2. Deduplicates the results by project key (a single `api/issues/reindex` call covers all branches and PRs for a project).
3. Calls `POST api/issues/reindex` for each affected project, re-queuing the indexing work.

## Requirements

- `curl`
- `jq`
- A SonarQube token with **Administer System** permission

## Usage

```bash
export SONAR_HOST_URL=https://sonarqube.example.com
export SONAR_TOKEN=squ_...
bash reindex.sh
```

## Monitoring progress

Once the script completes, the newly queued `ISSUE_SYNC` tasks can be monitored at:

**Administration → Background Tasks** (filter by type: `ISSUE_SYNC`)

Or directly via the Web API:

```
GET api/ce/activity?type=ISSUE_SYNC&status=IN_PROGRESS,PENDING
```

The global Issues page becomes available once all queued tasks have completed.

## References

- [After upgrade/redeploying SonarQube, Issues page is not available](https://help.sonarsource.com/hc/en-us/articles/28914049514898-After-upgrade-redeploying-SonarQube-Issues-page-is-not-available)
- [Reindexing — SonarQube Server documentation](https://docs.sonarsource.com/sonarqube-server/server-update-and-maintenance/maintenance/reindexing)
- [`api/issues/reindex` Web API reference](https://next.sonarqube.com/sonarqube/web_api/api/issues?query=reindex)
