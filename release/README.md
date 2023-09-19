# Fawkes

## Uploading to Nexus

```bash
./upload.sh
```

### Credential Precedence

The `upload.sh` script will use the `NEXUS_USERNAME` and `NEXUS_PASSWORD` environment variables if they are set.

If environment varialbes are not set, then by default the script will attempt to resolve credentials from a Kubernetes
secret called `nexus-admin-credential`. That Kubernetes secret should have the following information:

```yaml
apiVersion: v1
data:
  password: <value>
  username: <value>
kind: Secret
metadata:
  annotations:
    sealedsecrets.bitnami.com/cluster-wide: "true"
  name: nexus-admin-credential
  namespace: nexus
type: Opaque
```

If the Kubernetes secret is not available and no environment overrides were set, then default credentials are used as
defined in the `lib/install.sh` library.

### URL Precedence

By default, the Nexus URL is set in the `lib/install.sh` library. This can be overriden by setting the `NEXUS_URL`
environment variable before running `upload.sh`.

```bash
NEXUS_URL=http://my-nexus ./upload.sh
```

* Nexus credentials

## Viewing Nexus GUI

Visit http://<my-server-ip>/nexus/
