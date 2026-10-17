import { HttpAuthService, LoggerService } from '@backstage/backend-plugin-api';
import { Config } from '@backstage/config';
import express, { Router } from 'express';
import { PodStatusClient } from './service/podStatusClient';

export interface RouterOptions {
  logger: LoggerService;
  config: Config;
  httpAuth: HttpAuthService;
}

export async function createRouter(options: RouterOptions): Promise<Router> {
  const { logger, config, httpAuth } = options;
  const client = PodStatusClient.fromConfig(config, logger);
  const router = Router();
  router.use(express.json());

  // GET /api/pod-status/<namespace> -> [{name, status, ready, restarts, node}, ...]
  // httpAuth.credentials() is what makes this a *Backstage* endpoint, not an open proxy to the
  // cluster: only a request carrying a valid Backstage identity (a signed-in user, or another
  // plugin's service-to-service token) gets past this line.
  router.get('/:namespace', async (req, res) => {
    await httpAuth.credentials(req, { allow: ['user', 'service'] });
    const { namespace } = req.params;
    try {
      const pods = await client.listPods(namespace);
      res.json({ namespace, pods });
    } catch (error) {
      logger.error(`pod-status: failed to list pods for '${namespace}'`, error as Error);
      res.status(502).json({ error: (error as Error).message });
    }
  });

  return router;
}
