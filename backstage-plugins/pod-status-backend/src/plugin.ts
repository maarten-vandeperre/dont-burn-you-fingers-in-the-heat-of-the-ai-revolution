import {
  coreServices,
  createBackendPlugin,
} from '@backstage/backend-plugin-api';
import { createRouter } from './router';

/**
 * The pod-status backend plugin: registers one HTTP route (via httpRouter) and nothing else.
 * This is the entire "new backend system" shape every Backstage/RHDH backend plugin uses today --
 * compare to stack/developer-hub/dynamic-plugins.yaml's other `*-backend-dynamic` packages, which
 * are all built the same way, just with more routes and more injected services.
 */
export const podStatusPlugin = createBackendPlugin({
  pluginId: 'pod-status',
  register(env) {
    env.registerInit({
      deps: {
        logger: coreServices.logger,
        config: coreServices.rootConfig,
        httpAuth: coreServices.httpAuth,
        httpRouter: coreServices.httpRouter,
      },
      async init({ logger, config, httpAuth, httpRouter }) {
        httpRouter.use(await createRouter({ logger, config, httpAuth }));
        // No auth policy override here on purpose: the default (credentials required) is what
        // makes router.ts's own httpAuth.credentials() call meaningful. See README.md "Why this
        // isn't an open proxy to the cluster".
      },
    });
  },
});

export default podStatusPlugin;
