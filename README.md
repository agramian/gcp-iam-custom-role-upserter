# Google Cloud IAM Custom Role Upserter

A shell script for creating and editing / updating Google Cloud IAM custom roles using the `gcloud` CLI and `yq`.

## Dependencies

The following dependencies must be installed on the machine.

- [Bash](https://www.gnu.org/software/bash/) (tested on version 5.2)
- [yq](https://mikefarah.gitbook.io/yq) (tested on version 4.4)
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) (tested on version 463)

## Usage

```
Usage: ./gcp_iam_custom_role_upserter.sh [-d] [-p PROJECT_ID] [-o ORGANIZATION_ID] YAML_FILE
        -d                      Dry run mode. Prints the operations that would be performed without executing them.
        -p PROJECT_ID           Optional project ID to override the one in the YAML file.
        -o ORGANIZATION_ID      Optional organization ID to override the one in the YAML file.
```

## TODO

- [ ] Handle automatic exclusion of permissions which are not supported in custom roles
- [ ] Handle automatic exclusion of permissions which are not applicable for project-level custom roles (can only be added to
custom roles at the organization level and have no effect at the project level or below)

## Resources on GCP IAM

- [Custom Roles](https://cloud.google.com/iam/docs/roles-overview#custom)
- [Permissions Reference](https://cloud.google.com/iam/docs/permissions-reference)
