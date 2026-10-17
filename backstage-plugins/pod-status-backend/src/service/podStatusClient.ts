import { Config } from '@backstage/config';
import { LoggerService } from '@backstage/backend-plugin-api';

export interface PodStatus {
  name: string;
  status: string; // Deployment-level phase: Running, Pending, Failed, Succeeded, Unknown
  ready: string; // "1/1" style, from containerStatuses
  restarts: number;
  node: string;
}

/**
 * Talks straight to the Kubernetes/OpenShift API with a plain fetch() -- no @kubernetes/client-node
 * dependency, so this file is the whole lesson: a Bearer token, a namespaced REST path, and the
 * two fields (`status.phase`, `status.containerStatuses`) that make up "pod status" in the API.
 *
 * Config (app-config.yaml, see ../../README.md "3. Configure"):
 *   podStatus:
 *     clusterUrl: https://kubernetes.default.svc   # in-cluster API server
 *     token: ${POD_STATUS_TOKEN}                   # pod-status-reader ServiceAccount token
 *     skipTLSVerify: true                           # demo only; use the service CA in production
 */
export class PodStatusClient {
  private constructor(
    private readonly clusterUrl: string,
    private readonly token: string,
    private readonly skipTLSVerify: boolean,
    private readonly logger: LoggerService,
  ) {}

  static fromConfig(config: Config, logger: LoggerService): PodStatusClient {
    const clusterUrl = config.getString('podStatus.clusterUrl');
    const token = config.getString('podStatus.token');
    const skipTLSVerify = config.getOptionalBoolean('podStatus.skipTLSVerify') ?? false;
    return new PodStatusClient(clusterUrl, token, skipTLSVerify, logger);
  }

  async listPods(namespace: string): Promise<PodStatus[]> {
    const url = `${this.clusterUrl}/api/v1/namespaces/${encodeURIComponent(namespace)}/pods`;
    this.logger.debug(`pod-status: GET ${url}`);

    // skipTLSVerify only ever bypasses verification of the in-cluster service CA for this one
    // call, the same NODE_TLS_REJECT_UNAUTHORIZED=0 trade-off the rest of this Developer Hub
    // instance already makes for Argo CD and the Kubernetes API (see stack/developer-hub/backstage.yaml).
    const originalReject = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    if (this.skipTLSVerify) process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
    let response: Response;
    try {
      response = await fetch(url, {
        headers: {
          Authorization: `Bearer ${this.token}`,
          Accept: 'application/json',
        },
      });
    } finally {
      if (this.skipTLSVerify) process.env.NODE_TLS_REJECT_UNAUTHORIZED = originalReject;
    }

    if (!response.ok) {
      const body = await response.text();
      throw new Error(`Kubernetes API returned ${response.status} for namespace '${namespace}': ${body}`);
    }

    const payload = (await response.json()) as {
      items: Array<{
        metadata: { name: string };
        spec: { nodeName?: string };
        status: {
          phase: string;
          containerStatuses?: Array<{ ready: boolean; restartCount: number }>;
        };
      }>;
    };

    return payload.items.map(pod => {
      const containers = pod.status.containerStatuses ?? [];
      const readyCount = containers.filter(c => c.ready).length;
      const restarts = containers.reduce((sum, c) => sum + c.restartCount, 0);
      return {
        name: pod.metadata.name,
        status: pod.status.phase,
        ready: `${readyCount}/${containers.length}`,
        restarts,
        node: pod.spec.nodeName ?? '',
      };
    });
  }
}
